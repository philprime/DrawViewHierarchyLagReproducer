## Description

Calling `UIView.drawHierarchy(in:afterScreenUpdates: false)` to capture a simple onscreen window at native screen resolution causes recurring main-thread work lasting approximately 65 ms per call on a physical iPhone 14 Pro running iOS 27.2 (24B119). A separate iPhone 17 Pro simulator recording measured approximately 47 ms per call.

The attached standalone reproducer captures its window roughly once per second. Its screen contains a title, status text, pause/resume button, 48 static colored tiles, and a small moving marker. The controls and tile layout use SwiftUI. Window capture, run-loop scheduling, and marker animation use UIKit.

The capture path contains no third-party SDK, image encoding, disk writes, or networking. It draws into a fresh device-RGB bitmap context with 8 bits per component and premultiplied-last RGBA.

CPU samples consistently place the expensive work inside UIKit’s image-drawing path:

```text
CaptureViewController.render(window:)
  -[UIView drawViewHierarchyInRect:afterScreenUpdates:]
    -[UIImage drawInRect:blendMode:alpha:]
      -[UIImage _drawInContext:rect:layout:scale:applyContentsTransform:]
        CGContextDrawImage
          CGContextDrawImageWithOptions
            ripc_DrawImage
```

A signpost immediately surrounding `drawHierarchy` measures the UIKit call separately from bitmap allocation and subsequent `UIImage` creation.

## Production use case and impact

This capture path is used by Session Replay in the open-source [Sentry Cocoa SDK (`sentry-cocoa`)](https://github.com/getsentry/sentry-cocoa). We capture the application's visible UI approximately once per second to reconstruct the user's session. The recurring main-thread capture cost causes noticeable lag during scrolling in applications using replay. The attached project isolates the capture cost without integrating Sentry or its replay processing.

We do **not** need to force a layout pass, flush pending screen updates, or render a new frame. We only need the last rendered appearance of the view or window, ideally as readable pixel data that we can process off the main thread. A previously rendered frame is sufficient. The current implementation already passes `afterScreenUpdates: false`.

We cannot simply dispatch the view-hierarchy capture to a background queue: the UIKit view-hierarchy access and drawing must run on the main thread. Subsequent processing of the captured pixels can run elsewhere, but that does not remove the synchronous capture cost that interrupts scrolling.

The scrolling impact described here is our production-use observation. The physical-device and simulator measurements below quantify the isolated UIKit call, not scrolling performance or dropped-frame counts in a production application.

## Alternative considered: `layer.render(in:)`

We investigated replacing `drawHierarchy` with `view.layer.render(in:)`, but the alternative did not faithfully reproduce the visible UI. In our earlier testing, some icons, including SF Symbols, were missing or incompletely captured, making it unsuitable as a general replacement for replay capture.

The investigation is documented in [sentry-cocoa PR #4940: Add experimental flags to use a more efficient view renderer for Session Replay](https://github.com/getsentry/sentry-cocoa/pull/4940). Its section titled “Replacing `view.drawHierarchy(in:afterScreenUpdates:)` with `view.layer.render(in:)`” explicitly records that tab-bar icons were not rendered and includes an image showing the incomplete output.

A [follow-up discussion in the same PR](https://github.com/getsentry/sentry-cocoa/pull/4940#issuecomment-2739527250) also reports missing visual effects and notes that `layer.render(in:)` was slower than `drawHierarchy` in some other applications. For session replay, a lower-cost capture is not a suitable replacement if it omits visible UI elements.

## Environment

- **Xcode / Instruments:** 27.2 (27B52)
- **Host macOS:** 26.7.1 (25G241)
- **Build configuration:** Debug for both recordings
- **Profiler:** CPU Profiler, Normal sampling frequency

| Environment     | Model                                          | OS                 | Capture dimensions          |
| --------------- | ---------------------------------------------- | ------------------ | --------------------------- |
| Physical device | iPhone 14 Pro (iPhone15,2), connected by cable | iOS 27.2 (24B119)  | 1179 × 2556 pixels, scale 3 |
| Simulator       | iPhone 17 Pro                                  | iOS 27.2 (24B8117) | 1206 × 2622 pixels, scale 3 |

The physical-device recording ran on November 9, 2026, from 16:07:11.882 to 16:07:43.041 (UTC+01:00), with a configured 30-second time limit. These are separate device and simulator configurations, not a controlled comparison of hardware or OS builds. Whether this represents an OS regression has not been established.

## Steps to reproduce

1. Open the attached `DrawViewHierarchyLagReproducer.xcodeproj` in Xcode.
2. Select the `DrawViewHierarchyLagReproducer` scheme.
3. Select the connected iPhone 14 Pro running iOS 27.2 (24B119), with Developer Mode enabled. Use a valid development signing team for the app. Alternatively, use the iPhone 17 Pro simulator configuration above.
4. Build and run the app on the selected destination.
5. Wait for the capture counter to begin updating. Capture starts two seconds after the view appears.
6. Observe the reported capture durations and the marker moving along the bottom of the screen.
7. Tap **Pause / resume capture** to compare animation with capture enabled and disabled. Marker animation continues while capture is paused.
8. Record the app using Instruments’ **CPU Profiler** template.
9. Inspect the main-thread call tree and the `drawHierarchy` intervals in Points of Interest.

For the simulator-only Makefile workflow, from the project directory with the desired simulator booted:

```sh
make record DEVICE="SIMULATOR_UDID" DURATION=30s TRACE=Traces/feedback.trace
make inspect TRACE=Traces/feedback.trace
make open TRACE=Traces/feedback.trace
```

Replace `SIMULATOR_UDID` with the simulator’s identifier and use a new output trace path for each recording. The command-line workflow requires `make`, `jq`, and Python 3.

For a connected physical device, build and install with the project's existing signing configuration, then launch under CPU Profiler:

```sh
xcodebuild -quiet -project DrawViewHierarchyLagReproducer.xcodeproj \
  -scheme DrawViewHierarchyLagReproducer -configuration Debug \
  -destination "platform=iOS,id=DEVICE_UDID" -derivedDataPath .build build
xcrun devicectl device install app --device "DEVICE_UDID" \
  .build/Build/Products/Debug-iphoneos/DrawViewHierarchyLagReproducer.app
xcrun xctrace record --template "CPU Profiler" --device "DEVICE_UDID" \
  --time-limit 30s --output Traces/physical-device-feedback.trace \
  --launch -- io.sentry.bug-report.DrawVewHierarchyLagReproducer
make inspect TRACE=Traces/physical-device-feedback.trace
```

Replace `DEVICE_UDID` with the identifier reported by `xcrun devicectl list devices`. The bundle identifier above matches the attached project. Device installation requires valid development signing. No capture-code changes are needed between device and simulator runs.

## Expected results

For this small view hierarchy, I expected capture of the already rendered UI to have a lower main-thread cost, allowing once-per-second session replay capture to coexist with scrolling and normal interface animation without repeatedly consuming several frame budgets. We do not require pending view changes to be rendered before capture.

I understand that `drawHierarchy` performs synchronous drawing and has no documented latency guarantee. I am reporting the magnitude and recurrence of the drawing cost in this relatively simple case.

## Requested improvement

We would welcome either:

1. Improved performance of `drawHierarchy(in:afterScreenUpdates: false)` when capturing the existing onscreen appearance, reducing the work performed synchronously on the main thread.
2. A public API that provides access to the last rendered version of a view or window, ideally as readable pixel data or a bitmap, without requiring a new render or screen update. An asynchronous API that minimizes main-thread work would also meet this need.

The output needs to preserve the visible appearance, including SF Symbols and system-rendered effects. A visual snapshot usable only as a stand-in view would not meet our requirement unless it also provides access to the captured pixels for subsequent replay processing.

## Actual results

The physical-device run used a 30-second recording limit. The earlier simulator run used a 20-second limit.

| Measurement                          | iPhone 14 Pro, physical device | iPhone 17 Pro, simulator |
| ------------------------------------ | -----------------------------: | -----------------------: |
| Sampled UIKit drawing bursts         |                             26 |                       15 |
| Median interval between burst starts |                        1.083 s |                  1.050 s |
| Minimum `drawHierarchy` duration     |                        57.9 ms |                  36.0 ms |
| Median `drawHierarchy` duration      |                    **64.7 ms** |              **46.7 ms** |
| Maximum `drawHierarchy` duration     |                        69.4 ms |                  48.6 ms |

These durations were measured using signposts around the UIKit call itself, excluding bitmap allocation and `UIImage` creation. All 26 on-device `drawHierarchy` intervals reported `complete=1`. The whole on-device capture operation, measured by the outer `Capture` signpost, had a median duration of **68.9 ms** (61.7–73.2 ms range).

The expensive work recurs throughout both recordings rather than occurring only during startup. The 64.7 ms median on-device UIKit call occupies approximately 3.9 frame budgets at 60 Hz. The app requests 60 Hz marker updates, but actual display refresh rates and dropped-frame counts have not been measured.

On the physical device, the matching main-thread `drawHierarchy → CGContextDrawImage → ripc_DrawImage` stack accounted for 95.0% of sampled process CPU cycles. This is not 95.0% wall-clock CPU utilization: the app does comparatively little work between captures. Two CPU samples had no backtrace. Their cycles remain included in the process total and are not attributed to UIKit.

The capture loop waits one second after each capture completes, which explains the longer-than-one-second interval between bursts.

## Other

During an on-site lab with the SwiftUI team during the event “Boosting app performance” hosted by the Apple Performance Engineering team on October 29th, 2026, they raised to me that this behavior is unexpected and that I should surface it as a Feedback report. The engineers I talked to were Steven & Anil (no last names available).
