import Cocoa
import ScreenCaptureKit

// MARK: - ScrollCaptureController

/// Scroll capture engine:
///
/// - **`CGWindowListCreateImage`** for on-demand frame capture — each grab is a
///   complete, compositor-finished snapshot. No stream management, no stale frames.
/// - **TIFF byte-by-byte comparison** — two consecutive identical TIFF representations
///   = content has truly stopped rendering. Zero tolerance, no false positives.
/// - **Timer-driven `captureAndCompare`** on a dedicated serial queue — consistent
///   timing, no main-thread contention.
/// - **Incremental stitching** — `ScrollStitcher` appends only the new rows of
///   each frame, keeping memory bounded (no storing all raw strips).
/// - **Row matching that ignores what doesn't scroll** — `ScrollFrameMatcher`
///   aligns only the columns that move, cancels fixed backgrounds and leaves out
///   navbars (opaque or translucent) and pinned banners.
/// - **`matchNotFoundCount`** tracking — surfaces errors to the user via callbacks
///   instead of silently failing.
/// - **Programmatic scrolling** via `CGEventCreateScrollWheelEvent2`.
/// - **Sticky content appears once** — new rows are taken from just above a
///   pinned bottom banner, so headers stay at the top and banners at the end;
///   fixed sidebars beside the scrolling column are cropped away.
/// - **Continuous grabs while scrolling** — frames are taken every 50 ms during
///   a scroll, so a mouse wheel's large silent jumps can't outrun the overlap.
/// - **Vertical or horizontal** — the default follows content down the frame.
///   Horizontal capture transposes each frame (`ScrollAxis`), stitches columns
///   with the same pipeline, and transposes the finished image back.
/// - **Max size along the scroll: 30,000 pixels** (configurable via UserDefaults).
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false
    private var isCancelled: Bool = false
    /// Direction the session follows; vertical until the user switches it.
    private(set) var axis: ScrollAxis = .vertical

    /// Current estimated size of the final image along the scrolling axis, in
    /// points (height when vertical, width when horizontal).
    var estimatedTotalHeight: CGFloat {
        guard let merged = stitcher?.image else { return 0 }
        return CGFloat(merged.height) / backingScale
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Settings

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3
    private var maxScrollHeight: Int = 30000
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat

    // Dedicated serial queue for capture-and-compare (off main thread)
    private let captureQueue = DispatchQueue(label: "macshot.scrollcapture", qos: .userInitiated)

    // Frame state
    private var lastComparedTIFF: Data?  // TIFF of last settled frame for byte comparison
    private var stitcher: ScrollStitcher?

    // Match tracking
    private var matchNotFoundCount: Int = 0
    private let maxMatchNotFound: Int = 8  // stop after 8 consecutive failures
    private var didReportFirstMatch: Bool = false
    private var hasScrolledOnce: Bool = false
    private var consecutiveZeroShifts: Int = 0
    private let maxZeroShiftsBeforeStop: Int = 6

    // Scroll monitors (for manual scroll)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private(set) var autoScrollActive: Bool = false
    private var autoScrollTask: Task<Void, Never>?

    // Manual scroll throttle
    private let manualCaptureInterval: TimeInterval = 0.05
    private var lastScrollEventTime: TimeInterval = 0
    private var burstTimer: Timer?
    /// Keep grabbing this long after the last scroll event: a mouse wheel's
    /// smooth-scroll animation keeps moving the page without further events.
    private let burstTail: TimeInterval = 0.6
    private var pendingCaptureTask: Task<Void, Never>?
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.25

    // Guard: only one capture at a time
    private var isCapturing: Bool = false

    /// Bumped when a session starts over or ends. Captures still in flight from
    /// an older run stop touching the stitcher (a direction switch restarts).
    private var runID: Int = 0

    // Target app for scroll events
    private var targetAppPID: pid_t = 0

    // CGWindowList capture config
    private var targetWindowID: CGWindowID = kCGNullWindowID
    private var captureRectCG: CGRect = .zero  // CG coordinates (top-left origin)

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    /// - Parameter autoScroll: overrides the saved preference when the session
    ///   starts over (a direction switch keeps the mode chosen in the HUD).
    func startSession(autoScroll: Bool? = nil) async {
        // `didDeliver` also blocks a restart that was scheduled just before a
        // Stop: the session is over and must not come back to life.
        guard !isActive, !isCancelled, !didDeliver else { return }
        let run = runID

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // Convert AppKit coords to CG coords (top-left origin) for CGWindowListCreateImage
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(
            x: captureRect.origin.x,
            y: primaryScreenH - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        // Find the target window under the capture region
        resolveTargetWindow()
        resolveTargetApp()

        // Capture first settled frame
        guard let captured = await captureSettledFrame(run: run) else {
            if !isCancelled, run == runID { onSessionDone?(nil) }
            return
        }
        guard !isCancelled, run == runID else { return }
        // Horizontal capture stitches columns: the stitcher reads the frame
        // transposed, so grown "rows" become grown columns once it comes back.
        let firstFrame = axis.oriented(captured) ?? captured

        isActive = true
        stitcher = ScrollStitcher(firstFrame: firstFrame, handlesPinnedContent: frozenDetectionEnabled)
        matchNotFoundCount = 0
        didReportFirstMatch = false
        hasScrolledOnce = false
        consecutiveZeroShifts = 0
        stripCount = 1

        stitchedImage = firstFrame
        stitchedPixelSize = axis.pixelSize(of: firstFrame)
        emitPreview()
        onStripAdded?(stripCount)

        if autoScroll ?? autoScrollEnabled {
            startAutoScroll(run: run)
        } else {
            startManualScrollMonitors(run: run)
        }
    }

    /// Switches the direction the capture follows. A stitch already collected
    /// is in the old orientation, so it starts over in the new one; before the
    /// first strip lands that costs nothing, and the auto-scroll mode the user
    /// picked in the HUD is kept.
    func toggleAxis() {
        axis = axis.toggled
        guard isActive else { return }  // a startup still in flight reads the new axis
        restartSession()
    }

    private func restartSession() {
        let autoScroll = autoScrollActive
        runID &+= 1
        stopTimersAndMonitors()
        isActive = false
        stitcher = nil
        stripCount = 0
        stitchedImage = nil
        stitchedPixelSize = .zero
        matchNotFoundCount = 0
        didReportFirstMatch = false
        hasScrolledOnce = false
        consecutiveZeroShifts = 0
        Task { await startSession(autoScroll: autoScroll) }
    }

    /// Stops auto-scroll, the post-scroll timers and the scroll monitors.
    /// In-flight captures see a newer `runID` and leave the new session alone.
    private func stopTimersAndMonitors() {
        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        burstTimer?.invalidate(); burstTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false
    }

    private var didDeliver = false

    func stopSession() {
        // The HUD (and its Stop button) is on screen before `isActive` becomes
        // true — startSession first awaits a settled frame, which can take a
        // couple of seconds on a page with a blinking caret or a clock. A stop
        // in that window used to do nothing at all, and the session then
        // installed its scroll monitors anyway.
        // Delivers at most once: Stop, Return and ⌘C can all arrive for the
        // same session, and a second stop must not report an empty result.
        guard !didDeliver, isActive || !isCancelled else { return }
        didDeliver = true
        runID &+= 1
        guard isActive else {
            isCancelled = true
            onSessionDone?(nil)
            return
        }
        isActive = false

        stopTimersAndMonitors()

        // Deliver final image, back in screen orientation.
        let finalImage: NSImage?
        if let stitched = stitcher?.finish() {
            let cg = axis.oriented(stitched) ?? stitched
            let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                                height: CGFloat(cg.height) / backingScale)
            finalImage = NSImage(cgImage: cg, size: ptSize)
        } else {
            finalImage = nil
        }
        onSessionDone?(finalImage)
    }

    func cancelSession() {
        // Cancellation is also valid while the initial settled frame is being
        // captured, before `isActive` becomes true. The cancelled flag keeps
        // that asynchronous startup from installing monitors after the UI has
        // already been dismissed.
        isCancelled = true
        isActive = false
        runID &+= 1

        stopTimersAndMonitors()
    }

    // MARK: - Target window/app management

    /// Finds the window ID under the capture region center for targeted capture.
    private func resolveTargetWindow() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetWindowID = CGWindowID(winID)
                return
            }
        }
    }

    private func resolveTargetApp() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetAppPID = pid
                return
            }
        }
    }

    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Frame capture via CGWindowListCreateImage

    /// Captures the screen region using CGWindowListCreateImage.
    /// Returns a complete, compositor-finished snapshot — no stream management needed.
    private func captureFrame() -> CGImage? {
        let excludeSet = Set(excludedWindowIDs)
        let listOption: CGWindowListOption = [.optionOnScreenBelowWindow]
        let windowID = excludeSet.isEmpty ? kCGNullWindowID : (excludeSet.first ?? kCGNullWindowID)

        let imageOption: CGWindowImageOption = [.boundsIgnoreFraming]

        guard let image = CGWindowListCreateImage(
            captureRectCG, listOption, windowID, imageOption
        ) else { return nil }

        return image
    }

    /// Captures a settled frame: grabs frames until two consecutive TIFF representations
    /// match byte-for-byte. Used for initial capture and manual scroll mode.
    private func captureSettledFrame(run: Int) async -> CGImage? {
        var previousTIFF: Data? = nil
        var previousCG: CGImage? = nil
        var waitNs: UInt64 = 10_000_000  // 10ms

        for _ in 0..<30 {
            guard !isCancelled, run == runID else { return nil }
            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard !isCancelled, run == runID else { return nil }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                lastComparedTIFF = currentTIFF
                return cg
            }

            previousTIFF = currentTIFF
            previousCG = cg
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        return previousCG
    }

    // MARK: - Auto-scroll

    private func startAutoScroll(run: Int) {
        autoScrollActive = true
        onAutoScrollStarted?()

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        activateTargetApp()

        let linesPerTick: Int32
        switch autoScrollSpeed {
        case 1: linesPerTick = 1
        case 2: linesPerTick = 1
        case 4: linesPerTick = 2
        default: linesPerTick = 1
        }

        let burstCount: Int
        switch autoScrollSpeed {
        case 1: burstCount = 1
        case 2: burstCount = 2
        case 4: burstCount = 4
        default: burstCount = 3
        }

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, self.isActive, self.autoScrollActive, run == self.runID else { return }
            await self.autoScrollLoop(linesPerTick: linesPerTick, burstCount: burstCount, run: run)
        }
    }

    /// Sends one synthetic scroll step: down the frame, or right across it.
    private func postScroll(lines: Int32) {
        let event: CGEvent?
        switch axis {
        case .vertical:
            event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: -lines, wheel2: 0, wheel3: 0)
        case .horizontal:
            // With two wheels, `wheel2` is the horizontal axis.
            event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                            wheel1: 0, wheel2: -lines, wheel3: 0)
        }
        // Post at the session tap, not the HID tap. Mouse utilities such as
        // Mac Mouse Fix and LinearMouse rewrite wheel events at the HID tap and
        // would apply the user's "reverse direction" setting to this synthetic
        // event too, scrolling the page up instead of down (#186).
        event?.post(tap: .cgSessionEventTap)
    }

    /// Core auto-scroll loop: scroll → captureAndCompare → repeat.
    private func autoScrollLoop(linesPerTick: Int32, burstCount: Int, run: Int) async {
        while isActive && autoScrollActive && run == runID {
            // Post scroll event(s)
            for _ in 0..<burstCount {
                postScroll(lines: linesPerTick)
            }

            // captureAndCompare: settle, capture, compare, stitch.
            // `isCapturing` serializes this against a manual settledCapture
            // that may still be running — both mutate the stitcher and
            // stripCount around their suspension points.
            if isCapturing {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            isCapturing = true
            let success = await captureAndCompare(run: run)
            isCapturing = false
            guard run == runID else { return }

            if !success {
                matchNotFoundCount += 1
                if matchNotFoundCount >= maxMatchNotFound {
                    stopSession()
                    return
                }
            } else {
                matchNotFoundCount = 0
            }

            // Check the size limit. The stitcher grows along "rows", which are
            // the image's width when the capture is horizontal.
            if let merged = stitcher?.image, maxScrollHeight > 0 {
                if merged.height >= maxScrollHeight {
                    stopSession()
                    return
                }
            }

            // Small breathing room
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The core capture-and-compare cycle.
    /// Waits for pixel-perfect settlement via TIFF comparison, then computes the scroll
    /// offset via Vision and merges new content into the accumulated image.
    /// Returns true if a match was found, false if no shift detected.
    private func captureAndCompare(run: Int) async -> Bool {
        // Initial delay for scroll animation to begin
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Wait for settlement: poll frames until two consecutive TIFFs match
        var previousTIFF: Data? = nil
        var settledCG: CGImage? = nil
        var waitNs: UInt64 = 12_000_000

        for _ in 0..<30 {
            guard isActive, run == runID else { return false }

            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                settledCG = cg
                lastComparedTIFF = currentTIFF
                break
            }

            previousTIFF = currentTIFF
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        guard isActive, run == runID, let currentFrame = settledCG else { return false }
        switch process(currentFrame) {
        case .appended:
            consecutiveZeroShifts = 0
            return true
        case .noMovement:
            consecutiveZeroShifts += 1
            if hasScrolledOnce && consecutiveZeroShifts >= maxZeroShiftsBeforeStop {
                stopSession()
            }
            return false
        case .pending, .noMatch:
            return false
        }
    }

    // MARK: - Stitching

    /// Feeds a frame to the stitcher and reports new strips.
    /// The mouse pointer's area in a captured frame (pixels, top-left origin),
    /// generous enough for the large accessibility pointer sizes. The frame is
    /// already oriented for the axis, so the rect is mapped the same way.
    private func pointerRect(in frame: CGImage) -> CGRect? {
        let mouse = NSEvent.mouseLocation
        guard captureRect.insetBy(dx: -40, dy: -40).contains(mouse) else { return nil }
        let frameWidth = axis.isHorizontal ? CGFloat(frame.height) : CGFloat(frame.width)
        let scale = frameWidth / max(1, captureRect.width)
        let x = (mouse.x - captureRect.minX) * scale, y = (captureRect.maxY - mouse.y) * scale
        // The hotspot is the arrow's tip: the pointer extends down and right.
        return axis.oriented(CGRect(x: x - 8 * scale, y: y - 8 * scale, width: 48 * scale, height: 56 * scale))
    }

    private func process(_ frame: CGImage) -> ScrollStitcher.Outcome {
        guard let stitcher, let frame = axis.oriented(frame) else { return .noMatch }
        let outcome = stitcher.add(frame, pointer: pointerRect(in: frame))
        if outcome == .appended {
            hasScrolledOnce = true
            stripCount += 1
            didReportFirstMatch = true
            stitchedImage = stitcher.image
            stitchedPixelSize = axis.pixelSize(of: stitcher.image)

            emitPreview()
            onStripAdded?(stripCount)
        }
        return outcome
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    func toggleAutoScroll() {
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors(run: runID)
        } else {
            if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
            if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
            settlementTimer?.invalidate(); settlementTimer = nil
            burstTimer?.invalidate(); burstTimer = nil
            startAutoScroll(run: runID)
        }
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors(run: Int) {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            guard let self, run == self.runID else { return }
            self.onManualScrollEvent(run: run)
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, run == self.runID else { return event }
            self.onManualScrollEvent(run: run)
            return event
        }
    }

    /// A trackpad sends a stream of scroll events, but a mouse wheel sends one
    /// per notch and then animates the page silently. Grabbing only on events
    /// let a fast wheel move the page past the overlap between grabs (#484), so
    /// keep grabbing on a timer until the page has been still for a moment.
    private func onManualScrollEvent(run: Int) {
        guard isActive, run == runID else { return }
        lastScrollEventTime = ProcessInfo.processInfo.systemUptime
        settlementTimer?.invalidate(); settlementTimer = nil
        guard burstTimer == nil else { return }
        grabAndProcess()
        burstTimer = Timer.scheduledTimer(withTimeInterval: manualCaptureInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isActive, run == self.runID else { timer.invalidate(); return }
                if ProcessInfo.processInfo.systemUptime - self.lastScrollEventTime > self.burstTail {
                    timer.invalidate()
                    self.burstTimer = nil
                    // After scrolling stops, a final settled capture.
                    self.settlementTimer = Timer.scheduledTimer(withTimeInterval: self.settlementInterval,
                                                                repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            Task { @MainActor in await self.settledCapture(run: run) }
                        }
                    }
                    return
                }
                self.grabAndProcess()
            }
        }
    }

    /// Immediate frame grab + process during active scrolling.
    private func grabAndProcess() {
        guard isActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard let currentFrame = captureFrame() else { return }
        _ = process(currentFrame)
    }

    /// Final settled capture after scrolling stops — uses full TIFF settlement.
    private func settledCapture(run: Int) async {
        guard isActive, !isCapturing, run == runID else { return }
        isCapturing = true
        defer { isCapturing = false }

        let _ = await captureAndCompare(run: run)
    }

    // MARK: - Preview

    private func emitPreview() {
        guard let stitched = stitcher?.image, let callback = onPreviewUpdated else { return }
        // The preview is a picture of the page, so horizontal capture shows the
        // stitched columns upright again.
        let cg = axis.oriented(stitched) ?? stitched
        let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                            height: CGFloat(cg.height) / backingScale)
        callback(NSImage(cgImage: cg, size: ptSize))
    }
}
