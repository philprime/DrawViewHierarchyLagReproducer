# drawHierarchy main-thread lag reproducer

A standalone app for investigating the cost of UIKit's
`UIView.drawHierarchy(in:afterScreenUpdates:)` when capturing a simple onscreen
window roughly once per second. It is intended as a minimal project attachment
for Apple Feedback report **FB25502014**.

The reproducer contains no Sentry SDK, image encoding, disk writes, or networking
in its capture path. SwiftUI lays out the title, status text, pause button, and
static colored tiles. A UIKit view controller hosts these controls and keeps the
display-link marker, run-loop observer, and window capture in UIKit.

## Reproduce

### Requirements

- macOS with Xcode selected as the active developer directory.
- An installed and booted iOS simulator runtime.
- `make`, `jq`, and Python 3 for the command-line recording and inspection workflow.

The project and commands were validated with **Xcode 27.2 (27B52)** and an
**iPhone 17 Pro simulator running iOS 27.2 (24B8117)**. Compatibility with older Xcode
versions has not been verified.

### Run the app

1. Open Simulator and boot an iPhone simulator, preferably the configuration above.
2. From this repository's root, run:

   ```sh
   make run
   ```

3. Wait for the capture counter to start updating. The first capture is scheduled
   two seconds after the view appears.
4. Watch the marker moving along the bottom of the screen.
5. Tap **Pause / resume capture** to compare animation with and without screenshot
   capture. The marker continues moving while capture is paused.

The status label reports the **whole capture duration**, including bitmap setup
and image creation. It does not report only the UIKit drawing call.

You can also open `DrawViewHierarchyLagReproducer.xcodeproj` in Xcode and run the
`DrawViewHierarchyLagReproducer` scheme on an iOS simulator.

### Record and inspect

Stop any existing run of the app before recording. Use a new trace path for each
recording, because `xctrace` does not overwrite an existing trace bundle.

```sh
make record DURATION=30s TRACE=Traces/feedback.trace
make inspect TRACE=Traces/feedback.trace
make open TRACE=Traces/feedback.trace
```

`make record` builds, installs, and launches the app under the **CPU Profiler**
template. With no `TRACE` override, it chooses a timestamped path in `Traces/`.
The default recording duration is 20 seconds. No simulator code signing is needed.

If multiple simulators are booted, select one explicitly:

```sh
make record DEVICE="SIMULATOR_UDID" DURATION=30s
```

Replace `SIMULATOR_UDID` with the identifier shown by `xcrun simctl list devices`.

In Instruments:

- Inspect the main-thread call tree for the stack below.
- Inspect the `Capture` and `drawHierarchy` intervals in Points of Interest.
- Compare a period with capture enabled against a period paused using the button.

```text
CFRunLoop observer callback
  CaptureViewController.captureFrameIfNeeded()
    CaptureViewController.render(window:)
      -[UIView drawViewHierarchyInRect:afterScreenUpdates:]
        -[UIImage drawInRect:blendMode:alpha:]
          -[UIImage _drawInContext:rect:layout:scale:applyContentsTransform:]
            CGContextDrawImage
              CGContextDrawImageWithOptions
                ripc_DrawImage
```

`make inspect` exports CPU samples and signpost intervals to XML beside the trace.
It checks for at least five sampled drawing bursts with a median interval between
0.9 and 1.3 seconds, then prints the UIKit call durations measured by signposts.
It expects the CPU Profiler template, not Time Profiler.

## What the app isolates

The capture implementation is in
[`ContentView.swift`](Sources/ContentView.swift):

1. A 60 Hz display link moves the marker and wakes the main run loop.
2. A `beforeWaiting` observer, ordered at `CFIndex.max`, checks whether a capture
   is due. Capture is not performed on every display-link tick.
3. `render(window:)` allocates a fresh bitmap at native screen resolution:
   device RGB, 8 bits per component, and premultiplied-last RGBA.
4. It flips and scales the bitmap context to UIKit coordinates, pushes that
   context, and calls `window.drawHierarchy(in: bounds, afterScreenUpdates: false)`.
5. It creates a `UIImage` and retains only the most recent screenshot.
6. The next capture is scheduled one second after completion. A ~50 ms capture
   therefore produces bursts slightly more than one second apart.

This setup isolates the capture conditions used by `SentryViewRendererV2` and
`SentryGraphicsImageRenderer` without depending on those implementations. Using
`UIGraphicsImageRenderer` or a different snapshot API would be a separate
comparison, not the same reproduction.

## Observed result

A 20-second CPU Profiler recording of this version on the simulator configuration
above produced:

| Measurement                                                  |                Result |
| ------------------------------------------------------------ | --------------------: |
| Sampled UIKit drawing bursts                                 |                    15 |
| Median interval between burst starts                         |               1.050 s |
| Minimum / median / maximum `drawHierarchy` signpost duration | 36.0 / 46.7 / 48.6 ms |
| Median sampled burst span                                    |               38.5 ms |
| Matching drawing stack's share of sampled process CPU cycles |                 10.8% |

The expensive stack recurs rather than appearing only during startup. The
`drawHierarchy` signpost excludes bitmap allocation and `UIImage` creation, so
its duration attributes the bulk of the capture delay to the UIKit call itself.

These measurements are from a simulator under profiling. A separate physical
iPhone 14 Pro recording on iOS 27.2 (24B119) measured a median `drawHierarchy`
duration of **64.7 ms** across 26 captures. See [REPORT.md](REPORT.md) for the
on-device environment, reproduction commands, measurements, and diagnostic status.
The affected OS-version range and whether this is a regression have not been
established. Exact durations and CPU-cycle percentages vary between recordings.
A 46.7 ms main-thread call exceeds two 60 Hz frame budgets, but dropped-frame
counts have not been measured here.

CPU Profiler weights are **CPU cycles**, not memory usage or wall-clock time.
Sampled burst spans are not exact call durations. Use the signposts for durations.

The validated toolchain emitted a warning about an Instruments table without a
known input source. CPU samples and both signpost intervals still exported
successfully. Xcode also printed an empty-supported-platforms diagnostic while
the simulator build and static analysis completed successfully.

## Apple Feedback report

Suggested title: **UIKit drawHierarchy repeatedly occupies the main thread for
~50 ms when capturing a simple window in iOS Simulator**.

### Expected behavior

For this small hierarchy, periodic screenshot capture should have a lower
main-thread cost so it does not repeatedly consume several animation-frame
budgets. This is the performance expectation being reported, not a documented
latency guarantee of the API.

### Actual behavior

Calling `drawHierarchy(in:afterScreenUpdates: false)` at native screen scale
repeatedly takes approximately 47 ms in the measured simulator configuration.
CPU samples place the work in UIKit's image-drawing path through
`CGContextDrawImage` and `ripc_DrawImage`.

### Include with the report

- This source project, including the Makefile and inspection script.
- A fresh `.trace` recording from the environment used for the report.
- The output of `make inspect` for that recording.
- Exact Xcode, macOS, and simulator or physical-device OS versions and builds.
- The selected device model, build configuration, pixel dimensions, and display
  scale shown by the app. The Makefile defaults to Debug.
- If available, a recording with a paused interval or a screen recording showing
  the marker with capture enabled and paused.

Build products, traces, XML exports, and personal Xcode settings are ignored by
Git. Attach selected traces separately. Do not include `.build/` or `.git/` in
the source attachment.

## Maintenance

```sh
make help
make format
make analyze
```

For capture or scheduling changes, make a fresh recording and run `make inspect`
to confirm that the recurring UIKit stack remains reproducible. See
[AGENTS.md](AGENTS.md) for the reproduction conditions that should be preserved.
