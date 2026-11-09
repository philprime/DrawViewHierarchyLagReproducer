import Combine
import SwiftUI
import UIKit
import os.signpost

// SwiftUI lays out the controls. Capture and marker animation remain in UIKit.
struct ContentView: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> CaptureViewController {
    CaptureViewController()
  }

  func updateUIViewController(_ controller: CaptureViewController, context: Context) {}
}

private final class CaptureControlsState: ObservableObject {
  @Published var statusText =
    "Native scale · afterScreenUpdates: false\nCapture starts in 2 seconds. No Sentry SDK."
  var captureEnabled = true

  func toggleCapture() {
    // Animation continues while paused, providing a no-capture comparison.
    captureEnabled.toggle()
    statusText = captureEnabled ? "Capture resumed" : "Capture paused · animation continues"
  }
}

private struct CaptureControls: View {
  @ObservedObject var state: CaptureControlsState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("drawHierarchy reproducer")
        .font(.system(size: 23, weight: .bold))

      Text(state.statusText)
        .font(.system(size: 14, design: .monospaced))

      Button("Pause / resume capture", action: state.toggleCapture)
        .frame(maxWidth: .infinity)

      // A small, static hierarchy. No images are generated or decoded per capture.
      ForEach(0..<8, id: \.self) { row in
        HStack(spacing: 6) {
          ForEach(0..<6, id: \.self) { column in
            Color(hue: Double(row * 6 + column) / 48, saturation: 0.65, brightness: 0.9)
          }
        }
        .frame(height: 44)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Captures the visible window at native screen resolution, roughly once per second.
/// Look for render(window:) → drawViewHierarchyInRect: → CGContextDrawImage → ripc_DrawImage
/// on the main thread in Instruments. The goal is to isolate UIKit's drawing cost,
/// without replay masking, image encoding, disk writes, or networking.
final class CaptureViewController: UIViewController {
  private let captureLog = OSLog(
    subsystem: "DrawViewHierarchyLagReproducer", category: .pointsOfInterest)
  private let controlsState = CaptureControlsState()
  private let animationMarker = UIView()

  private var displayLink: CADisplayLink?
  private var captureObserver: CFRunLoopObserver?
  private var nextCaptureTime = 0.0
  private var captureCount = 0

  // Keep only the latest screenshot. Do not display it or accumulate screenshots.
  private var lastImage: UIImage?

  // MARK: - Screen content

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let controls = UIHostingController(rootView: CaptureControls(state: controlsState))
    addChild(controls)
    controls.view.frame = view.bounds
    controls.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(controls.view)
    controls.didMove(toParent: self)

    animationMarker.backgroundColor = .label
    animationMarker.frame = CGRect(x: 20, y: 0, width: 12, height: 12)
    view.addSubview(animationMarker)
  }

  // MARK: - Main-thread scheduling

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startCaptureLoop()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopCaptureLoop()
  }

  private func startCaptureLoop() {
    guard displayLink == nil else { return }

    // Let the initial layout and onscreen rendering finish before the first capture.
    nextCaptureTime = CACurrentMediaTime() + 2
    startMarkerAnimation()
    installCaptureObserver()
  }

  private func startMarkerAnimation() {
    // This runs at 60 Hz, but does not capture. It animates the marker and wakes the
    // run loop so that the capture observer gets an opportunity to check the deadline.
    let link = CADisplayLink(target: self, selector: #selector(animateMarker))
    link.preferredFramesPerSecond = 60
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func installCaptureObserver() {
    // Capture at the end of a run-loop iteration, after other observers have run.
    // This mirrors replay's scheduling point rather than using a repeating timer.
    captureObserver = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault,
      CFRunLoopActivity.beforeWaiting.rawValue,
      true,
      CFIndex.max
    ) { [weak self] _, _ in
      // The observer is registered only on the main run loop.
      MainActor.assumeIsolated {
        self?.captureFrameIfNeeded()
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), captureObserver, .commonModes)
  }

  private func stopCaptureLoop() {
    displayLink?.invalidate()
    displayLink = nil
    if let captureObserver {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), captureObserver, .commonModes)
    }
    captureObserver = nil
  }

  @objc private func animateMarker() {
    let progress = CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: 2) / 2)
    animationMarker.frame.origin = CGPoint(
      x: 20 + progress * max(0, view.bounds.width - 52),
      y: view.bounds.height - view.safeAreaInsets.bottom - 30
    )
  }

  // MARK: - Screenshot capture

  // Keep the capture methods identifiable in optimized Instruments call stacks.
  @inline(never)
  private func captureFrameIfNeeded() {
    guard controlsState.captureEnabled, CACurrentMediaTime() >= nextCaptureTime,
      let window = view.window
    else { return }

    // "Capture" measures the entire screenshot operation. The nested "drawHierarchy"
    // signpost in render(window:) measures only the UIKit call we are investigating.
    let signpostID = OSSignpostID(log: captureLog)
    os_signpost(.begin, log: captureLog, name: "Capture", signpostID: signpostID)
    let start = CACurrentMediaTime()
    autoreleasepool {
      lastImage = render(window: window)
    }
    let elapsedMilliseconds = (CACurrentMediaTime() - start) * 1_000
    os_signpost(
      .end, log: captureLog, name: "Capture", signpostID: signpostID, "%.3f ms", elapsedMilliseconds
    )

    captureCount += 1
    controlsState.statusText = String(
      format: "Capture #%d · %.1f ms\n%.0f × %.0f pixels · scale %.0f",
      captureCount, elapsedMilliseconds,
      window.bounds.width * window.screen.scale,
      window.bounds.height * window.screen.scale, window.screen.scale)

    // A one-second delay AFTER completion yields a period of ~1s + drawing time.
    // Do not catch up missed captures: that would create a different tracing pattern.
    nextCaptureTime = CACurrentMediaTime() + 1
  }

  @inline(never)
  private func render(window: UIWindow) -> UIImage? {
    let bounds = window.bounds
    let scale = window.screen.scale
    let pixelWidth = Int(bounds.width * scale)
    let pixelHeight = Int(bounds.height * scale)
    let bytesPerRow = pixelWidth * 4

    // Match SentryGraphicsImageRenderer: a fresh, zeroed, 8-bit RGBA bitmap at native
    // screen scale. UIGraphicsImageRenderer has its own context caching behavior,
    // so substituting it would change the conditions of this reproduction.
    guard let pixels = calloc(pixelHeight * bytesPerRow, 1) else { return nil }
    defer { free(pixels) }
    guard
      let context = CGContext(
        data: pixels, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    // UIKit draws in points with a top-left origin. Map that to the pixel bitmap,
    // then make it UIKit's current drawing context for drawHierarchy.
    context.translateBy(x: 0, y: bounds.height * scale)
    context.scaleBy(x: scale, y: -scale)
    UIGraphicsPushContext(context)

    let signpostID = OSSignpostID(log: captureLog)
    os_signpost(.begin, log: captureLog, name: "drawHierarchy", signpostID: signpostID)
    // This is the call under investigation. false captures the existing onscreen
    // contents without requesting pending screen updates, matching SentryViewRendererV2.
    let complete = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
    os_signpost(
      .end, log: captureLog, name: "drawHierarchy", signpostID: signpostID,
      "complete=%d", complete ? 1 : 0)

    UIGraphicsPopContext()
    guard let image = context.makeImage() else { return nil }
    return UIImage(cgImage: image, scale: scale, orientation: .up)
  }
}
