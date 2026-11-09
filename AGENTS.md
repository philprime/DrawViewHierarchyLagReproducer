# AGENTS.md

Standalone UIKit performance reproducer intended for an Apple Feedback report.
Read [README.md](README.md) for reproduction steps and measured results.

## Preserve the reproduction

- Keep the app independent of Sentry and other third-party dependencies.
- Keep the visible hierarchy small. Do not add synthetic drawing load to make the issue appear worse.
- Capture the entire visible `UIWindow` on the main thread at native screen scale.
- Preserve `drawHierarchy(in:afterScreenUpdates: false)` and the explicit bitmap context:
  device RGB, 8 bits per component, premultiplied-last RGBA, and the UIKit coordinate transform.
- Do not substitute `UIGraphicsImageRenderer`, `layer.render(in:)`, or snapshot APIs unless the task explicitly requests a comparison.
- Keep capture in the main run loop's `beforeWaiting` observer at `CFIndex.max` order.
- Preserve the two-second startup delay and one-second delay after capture completion.
  The display link animates the marker and wakes the run loop, not the capture cadence.
- Retain the pause/resume comparison and only the latest screenshot.
- Keep `Capture` and nested `drawHierarchy` signposts, their names, and the non-inlined capture methods.
  The inspection script depends on the `drawHierarchy` signpost name.
- Keep image encoding, file writes, and networking out of the capture path.

## Verification

- Run `make format` after Swift changes and `make analyze` for code changes.
- After capture or scheduling changes, run `make record DURATION=20s`, then
  `make inspect TRACE=...` using the path printed by the recording command.
  `make record` also builds and installs the app on a booted iOS simulator.
- `make inspect` expects a CPU Profiler recording. Keep previous recordings and use a new output name.
- For inspection-script changes, check against an existing recording before recording again.
- Report UIKit signpost durations separately from sampled burst spans and CPU-cycle weights.
  CPU-cycle percentages are not percentages of wall-clock time or memory usage.
- Do not describe simulator measurements as physical-device results, infer a regression without
  a comparison, or claim dropped frames without measuring them.

## Local artifacts

- Keep `.build/`, `Traces/`, Xcode user settings, and trace XML exports ignored.
- Do not commit trace bundles or personal Xcode settings by default. Recordings for Apple
  Feedback are selected and attached separately by the user.
