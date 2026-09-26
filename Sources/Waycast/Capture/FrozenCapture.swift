//
//  FrozenCapture.swift
//  Waycast
//
//  Ported from Mio's CapturePipeline (github.com/iSoldLeo/Mio, GPL-3.0),
//  adapted to Swift 5.9 / macOS 14. Core idea: NEVER pick from the live
//  screen. Freeze every display into a still CGImage first, let the user
//  take their time on the still frames, then (for window picks) do an
//  on-demand ScreenCaptureKit desktop-independent-window capture with
//  transparent rounded corners.
//
//  Tahoe notes (root-caused 2026-09-19):
//  1. Shadows: on macOS 26 the legacy SCStreamConfiguration captureImage path
//     silently drops ALL window shadows on full-display captures —
//     ignoreShadowsDisplay=false does NOT bring them back (Mio, the upstream
//     project, has the same defect). Streams keep them.
//  2. Zoom animation: on macOS 26 EVERY screenshot-semantics capture triggers
//     the system's screenshot zoom animation (screen scales up to fill) —
//     SCScreenshotManager (both APIs) AND /usr/sbin/screencapture CLI all
//     play it. The one public path that does NOT is SCStream: streaming is
//     "screen share" semantics (Zoom/OBS), never animated. So the default
//     path is a stream started, first frame grabbed, stream stopped; CLI and
//     SCScreenshotManager remain as fallbacks only.
//

import AppKit
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit

/// One display frozen into a still image. `scale` = pixels per point.
struct FrozenScreen {
    let displayID: CGDirectDisplayID
    /// AppKit points, bottom-left origin (matches NSScreen.frame).
    let frame: CGRect
    let image: CGImage
    let scale: CGFloat
}

enum FrozenCaptureError: Error {
    case noDisplays
    case windowUnavailable
    case captureFailed
}

enum FrozenCapture {

    /// Touch SCK once at launch so the first capture doesn't pay the
    /// shareable-content enumeration cost.
    ///
    /// 光枚举 shareable content 不够：实测**启动后第一次抓屏要 197ms**，
    /// 而真正贵的是"第一次把 SCStream 管线跑起来"（冷启动 ~67ms）+ 那时
    /// 应用还在做别的初始化（Vision 模型加载等）。所以这里干脆空跑一整条
    /// 默认抓屏路径，把管线预热掉，结果直接丢掉。
    static func prewarm() async {
        _ = try? await shareableContent()
        _ = try? await displayList()          // 顺手把显示器列表也缓存上
        _ = try? await captureAllScreens()    // 空跑一次：让第一次真按键就是"热"的
    }

    /// Freeze every connected display concurrently.
    static func captureAllScreens() async throws -> [FrozenScreen] {
        // Isolation test: WAYCAST_NO_CAPTURE (defaults key or env) skips every
        // capture API and hands back synthetic solid frames. If the zoom
        // animation still appears with this set, the trigger is the overlay
        // window itself, not any capture path.
        // Defaults key preferred over env var: launching the binary directly
        // from Terminal makes TCC attribute captures to Terminal, breaking
        // the screen-recording check.
        if UserDefaults.standard.bool(forKey: "WAYCAST_NO_CAPTURE")
            || ProcessInfo.processInfo.environment["WAYCAST_NO_CAPTURE"] == "1" {
            return await Self.syntheticScreens()
        }
        // Preferred: SCStream single-frame. Streaming has "screen share"
        // semantics on macOS 26 and never plays the screenshot zoom animation
        // (unlike SCScreenshotManager and the screencapture CLI, which both do).
        let hadCachedDisplays = isDisplayCacheFresh()
        if let screens = try? await captureAllScreensViaStream(), !screens.isEmpty {
            return screens
        }
        // 只有**确实用了缓存**才重试一次：缓存可能已过期（插拔显示器 / 分辨率变了），
        // 清掉再枚举一次就行。之后再降级到 CLI —— CLI 要 136–186ms 而且会触发
        // Tahoe 的缩放动画，是最后手段，不该被一次陈旧缓存骗出来。
        if hadCachedDisplays {
            invalidateDisplayCache()
            if let screens = try? await captureAllScreensViaStream(), !screens.isEmpty {
                return screens
            }
        }
        if let screens = try? await captureAllScreensViaCLI(), !screens.isEmpty {
            return screens
        }
        return try await captureAllScreensViaSCK()
    }

    private static func syntheticScreens() async -> [FrozenScreen] {
        await MainActor.run {
            NSScreen.screens.compactMap { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? CGDirectDisplayID else { return nil }
                let w = Int(screen.frame.width * screen.backingScaleFactor)
                let h = Int(screen.frame.height * screen.backingScaleFactor)
                let image = NSImage(size: NSSize(width: w, height: h))
                image.lockFocus()
                NSColor.systemGray.setFill()
                NSRect(x: 0, y: 0, width: w, height: h).fill()
                image.unlockFocus()
                guard
                    let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let cg = rep.cgImage
                else { return nil }
                return FrozenScreen(displayID: id, frame: screen.frame,
                                    image: cg, scale: screen.backingScaleFactor)
            }
        }
    }

    // MARK: SCStream single-frame path (default)

    // 显示器列表缓存：`SCShareableContent` 每次要 ~11–20ms（实测），而按 F1 这条
    // 路径上一秒内可能连点好几次。显示器拓扑平时几乎不变，缓存 30 秒就够；
    // 窗口列表**不**缓存（随时在变），所以窗口截图那条路仍然现取。
    private static let displayCacheLock = NSLock()
    private static var cachedDisplays: (list: [SCDisplay], at: CFTimeInterval)?

    /// 把加锁区放进**同步**函数里：直接在 async 函数体内调 `lock()/unlock()`
    /// 会吃 "unavailable from asynchronous contexts" 告警（Swift 6 下是错误）。
    private static func withCacheLock<T>(_ body: () -> T) -> T {
        displayCacheLock.lock()
        defer { displayCacheLock.unlock() }
        return body()
    }

    /// 插拔显示器 / 改分辨率时调一次，让下次截图重新枚举。
    static func invalidateDisplayCache() {
        withCacheLock { cachedDisplays = nil }
    }

    private static func isDisplayCacheFresh() -> Bool {
        withCacheLock {
            guard let c = cachedDisplays else { return false }
            return !c.list.isEmpty && CACurrentMediaTime() - c.at < 30
        }
    }

    private static func displayList() async throws -> [SCDisplay] {
        if let hit = withCacheLock({ cachedDisplays.flatMap {
            CACurrentMediaTime() - $0.at < 30 ? $0.list : nil
        } }), !hit.isEmpty { return hit }

        let list = try await shareableContent().displays
        withCacheLock { cachedDisplays = (list, CACurrentMediaTime()) }
        return list
    }

    private static func captureAllScreensViaStream() async throws -> [FrozenScreen] {
        let displays = Dictionary(uniqueKeysWithValues: try await displayList().map { ($0.displayID, $0) })
        let topology = await MainActor.run {
            NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect, CGFloat)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? CGDirectDisplayID else { return nil }
                return (id, screen.frame, screen.backingScaleFactor)
            }
        }
        guard !topology.isEmpty else { throw FrozenCaptureError.noDisplays }

        return try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
            for (id, frame, _) in topology {
                guard let display = displays[id] else { continue }
                group.addTask {
                    try await captureDisplayViaStream(display: display, frame: frame)
                }
            }
            var out: [FrozenScreen] = []
            for try await screen in group { out.append(screen) }
            guard !out.isEmpty else { throw FrozenCaptureError.captureFailed }
            return out.sorted { $0.displayID < $1.displayID }
        }
    }

    private static func captureDisplayViaStream(display: SCDisplay, frame: CGRect) async throws -> FrozenScreen {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((frame.width * scale).rounded()))
        config.height = max(2, Int((frame.height * scale).rounded()))
        config.showsCursor = false
        config.shouldBeOpaque = true
        config.queueDepth = 1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        if #available(macOS 15.0, *) {
            config.captureResolution = .best
            config.captureDynamicRange = .SDR   // match the on-screen appearance
        }
        let image = try await firstFrame(filter: filter, config: config)
        return FrozenScreen(displayID: display.displayID, frame: frame, image: image, scale: scale)
    }

    /// Grabs exactly one frame from a stream, then signals completion. All
    /// state is confined to `queue`, which doubles as the sample-handler
    /// queue, so no extra locking is needed.
    private final class SingleFrameGrabber: NSObject, SCStreamOutput {
        private static let ciContext = CIContext(options: [
            CIContextOption.outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])

        let queue = DispatchQueue(label: "waycast.stream.frame", qos: .userInitiated)
        private var continuation: CheckedContinuation<CGImage, Error>?
        private var finished = false

        func firstFrame(timeout: TimeInterval) async throws -> CGImage {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    guard !self.finished else {
                        cont.resume(throwing: FrozenCaptureError.captureFailed)
                        return
                    }
                    self.continuation = cont
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(FrozenCaptureError.captureFailed))
                    }
                }
            }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cg = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                finish(.failure(FrozenCaptureError.captureFailed))
                return
            }
            finish(.success(cg))
        }

        private func finish(_ result: Result<CGImage, Error>) {
            guard !finished else { return }
            finished = true
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// Starts a stream on `filter`, returns its first frame, stops the stream.
    private static func firstFrame(filter: SCContentFilter,
                                   config: SCStreamConfiguration) async throws -> CGImage {
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let grabber = SingleFrameGrabber()
        try stream.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: grabber.queue)
        do {
            try await stream.startCapture()
            let image = try await grabber.firstFrame(timeout: 4)
            try? await stream.stopCapture()
            return image
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }

    // MARK: CLI path (default)

    private static func captureAllScreensViaCLI() async throws -> [FrozenScreen] {
        let topology = await MainActor.run {
            NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect, CGFloat)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? CGDirectDisplayID else { return nil }
                return (id, screen.frame, screen.backingScaleFactor)
            }
        }
        guard !topology.isEmpty else { throw FrozenCaptureError.noDisplays }

        // Global display-space bounds (top-left origin) for -R coordinates.
        var union: CGRect?
        for (_, frame, _) in topology {
            union = union.map { $0.union(frame) } ?? frame
        }
        guard let global = union else { throw FrozenCaptureError.noDisplays }

        return try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
            for (id, frame, _) in topology {
                group.addTask {
                    try await captureRegionViaCLI(displayID: id, frame: frame, globalBounds: global)
                }
            }
            var out: [FrozenScreen] = []
            for try await screen in group { out.append(screen) }
            guard !out.isEmpty else { throw FrozenCaptureError.captureFailed }
            return out.sorted { $0.displayID < $1.displayID }
        }
    }

    /// One display via `screencapture -R` (region in global points,
    /// top-left origin). Runs the CLI concurrently per display.
    private static func captureRegionViaCLI(displayID: CGDirectDisplayID,
                                            frame: CGRect,
                                            globalBounds: CGRect) async throws -> FrozenScreen {
        let tmpURL = URL(fileURLWithPath: "/tmp/waycast_cli_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let cgFrame = CGRect(x: frame.minX,
                             y: globalBounds.maxY - frame.maxY,
                             width: frame.width,
                             height: frame.height)
        let arguments = [
            "-x",
            String(format: "-R%.0f,%.0f,%.0f,%.0f",
                   cgFrame.minX, cgFrame.minY, cgFrame.width, cgFrame.height),
            tmpURL.path,
        ]
        try await runScreencapture(arguments)

        let data = try Data(contentsOf: tmpURL)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FrozenCaptureError.captureFailed }
        // Derive pixels-per-point from the actual output (handles mixed-DPI
        // multi-display setups without trusting NSScreen hints).
        let scale = CGFloat(image.width) / frame.width
        return FrozenScreen(displayID: displayID, frame: frame, image: image, scale: scale)
    }

    private static func runScreencapture(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = arguments
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: FrozenCaptureError.captureFailed)
                }
            }
        }
    }

    // MARK: SCK path (fallback)

    private static func captureAllScreensViaSCK() async throws -> [FrozenScreen] {
        let content = try await shareableContent()
        let displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let topology = await MainActor.run {
            NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect, CGFloat)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? CGDirectDisplayID else { return nil }
                return (id, screen.frame, screen.backingScaleFactor)
            }
        }
        guard !topology.isEmpty else { throw FrozenCaptureError.noDisplays }

        return try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
            for (id, frame, backingScale) in topology {
                guard let display = displays[id] else { continue }
                group.addTask {
                    try await captureDisplay(display: display,
                                             frame: frame,
                                             backingScale: backingScale)
                }
            }
            var out: [FrozenScreen] = []
            for try await screen in group { out.append(screen) }
            return out.sorted { $0.displayID < $1.displayID }
        }
    }

    /// On-demand capture of one real window with transparent rounded corners
    /// (no wallpaper bleeding into the alpha channel).
    static func captureWindow(windowID: CGWindowID, ownerPID: pid_t) async throws -> CGImage {
        // Stream first: single frame from a desktop-independent-window stream
        // keeps the drop shadow AND avoids Tahoe's screenshot zoom animation.
        if let image = try? await captureWindowViaStream(windowID: windowID, ownerPID: ownerPID) {
            return image
        }
        if let image = try? await captureWindowViaCLI(windowID: windowID) {
            return image
        }
        return try await captureWindowViaSCK(windowID: windowID, ownerPID: ownerPID)
    }

    private static func captureWindowViaStream(windowID: CGWindowID, ownerPID: pid_t) async throws -> CGImage {
        let content = try await shareableContent()
        guard
            let window = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == ownerPID
            })
        else { throw FrozenCaptureError.windowUnavailable }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        config.showsCursor = false
        // false = KEEP the window's drop shadow (true would explicitly exclude it).
        config.ignoreShadowsSingleWindow = false
        config.shouldBeOpaque = false
        config.queueDepth = 1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        if #available(macOS 15.0, *) { config.captureResolution = .best }
        return try await firstFrame(filter: filter, config: config)
    }

    private static func captureWindowViaCLI(windowID: CGWindowID) async throws -> CGImage {
        let tmpURL = URL(fileURLWithPath: "/tmp/waycast_cli_win_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try await runScreencapture(["-x", "-l\(windowID)", tmpURL.path])
        let data = try Data(contentsOf: tmpURL)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FrozenCaptureError.captureFailed }
        return image
    }

    private static func captureWindowViaSCK(windowID: CGWindowID, ownerPID: pid_t) async throws -> CGImage {
        let content = try await shareableContent()
        guard
            let window = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == ownerPID
            })
        else { throw FrozenCaptureError.windowUnavailable }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        config.showsCursor = false
        // No explicit backgroundColor: the default is already transparent, and
        // assigning a CGColor here reliably corrupts SCStreamConfiguration's
        // copy on macOS 26 (EXC_BREAKPOINT in CFRetain during copyWithZone).
        // false = KEEP the window's drop shadow (true would explicitly
        // exclude it, and macOS 26's default also drops it for this path).
        config.ignoreShadowsSingleWindow = false
        config.shouldBeOpaque = false
        if #available(macOS 15.0, *) { config.captureResolution = .best }
        return try await captureImage(filter: filter, config: config)
    }

    // MARK: - Internals

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func captureDisplay(display: SCDisplay, frame: CGRect, backingScale: CGFloat) async throws -> FrozenScreen {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)

        let image: CGImage
        if #available(macOS 26.0, *) {
            // Tahoe: legacy captureImage drops window shadows on full-display
            // captures no matter what ignoreShadowsDisplay says. The 26-only
            // captureScreenshot API keeps them and matches what the user sees.
            let config = SCScreenshotConfiguration()
            config.ignoreShadows = false    // keep window shadows
            config.showsCursor = false
            config.dynamicRange = .sdr      // SDR: matches the on-screen appearance
            image = try await captureScreenshot(filter: filter, config: config)
        } else {
            image = try await captureDisplayImage(display: filter, size: frame.size,
                                                  keepShadows: true, sdr: true)
        }
        return FrozenScreen(displayID: display.displayID, frame: frame, image: image, scale: scale)
    }

    private static func captureDisplayImage(display filter: SCContentFilter, size: CGSize,
                                            keepShadows: Bool, sdr: Bool) async throws -> CGImage {
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((size.width * scale).rounded()))
        config.height = max(2, Int((size.height * scale).rounded()))
        config.showsCursor = false
        config.shouldBeOpaque = true
        if keepShadows {
            config.ignoreShadowsDisplay = false      // keep window shadows (Tahoe dropped them by default)
        }
        if #available(macOS 15.0, *) {
            config.captureResolution = .best
            if sdr {
                config.captureDynamicRange = .SDR    // match what the user actually sees
            }
        }
        return try await captureImage(filter: filter, config: config)
    }

    /// SCScreenshotManager calls are serialized on a dedicated queue: the
    /// completion-based API copies the configuration on an internal queue, and
    /// overlapping operations on macOS 26 have been observed to crash inside
    /// -[SCStreamConfiguration copyWithZone:] (use-after-free of its color
    /// ivars). A serial queue guarantees one capture in flight at a time.
    private static let screenshotQueue = DispatchQueue(label: "waycast.screenshot", qos: .userInitiated)

    /// macOS 26+ shadow-preserving full-display screenshot.
    @available(macOS 26.0, *)
    private static func captureScreenshot(filter: SCContentFilter,
                                          config: SCScreenshotConfiguration) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { continuation in
            screenshotQueue.async { [config, filter] in
                SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, error in
                    if let image = output?.sdrImage {
                        continuation.resume(returning: image)
                    } else {
                        _ = error
                        continuation.resume(throwing: FrozenCaptureError.captureFailed)
                    }
                }
            }
        }
    }

    private static func captureImage(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            // Strong-capture config/filter so they outlive the async call.
            screenshotQueue.async { [config, filter] in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [config, filter] image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        _ = error
                        continuation.resume(throwing: FrozenCaptureError.captureFailed)
                    }
                }
            }
        }
    }

    // MARK: - Latency benchmark (developer hook)

    /// 把每条抓帧路径、每个阶段都量一遍，用于回答「按 F1 之后那几十~几百毫秒花在哪」。
    private static func elapsed(_ t: CFTimeInterval) -> String {
        String(format: "%7.1f", (CACurrentMediaTime() - t) * 1000)
    }

    static func bench(iterations: Int) async -> String {
        var lines: [String] = []

        // ① 枚举 shareable content —— 每条路径开头都要做一遍。
        for i in 0..<iterations {
            let t = CACurrentMediaTime()
            let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            lines.append("  SCShareableContent[\(i)]  \(elapsed(t)) ms"
                         + "  (displays=\(c?.displays.count ?? -1) windows=\(c?.windows.count ?? -1))")
        }

        // ② 单个显示器：启流 / 等首帧 / 停流 三段分解。
        if let content = try? await shareableContent() {
            let topology = await MainActor.run {
                NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID else { return nil }
                    return (id, screen.frame)
                }
            }
            for (id, frame) in topology {
                guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                for i in 0..<iterations {
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let scale = CGFloat(filter.pointPixelScale)
                    let config = SCStreamConfiguration()
                    config.width = max(2, Int((frame.width * scale).rounded()))
                    config.height = max(2, Int((frame.height * scale).rounded()))
                    config.showsCursor = false
                    config.shouldBeOpaque = true
                    config.queueDepth = 1
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    if #available(macOS 15.0, *) {
                        config.captureResolution = .best
                        config.captureDynamicRange = .SDR
                    }
                    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                    let grabber = SingleFrameGrabber()
                    try? stream.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: grabber.queue)

                    let t0 = CACurrentMediaTime()
                    try? await stream.startCapture()
                    let t1 = CACurrentMediaTime()
                    let image = try? await grabber.firstFrame(timeout: 4)
                    let t2 = CACurrentMediaTime()
                    try? await stream.stopCapture()
                    let t3 = CACurrentMediaTime()
                    let dims = image.map { "\($0.width)x\($0.height)" } ?? "nil"
                    lines.append("  stream disp\(id)[\(i)]  start=\(elapsed(t0))"
                                 + "  firstFrame=\(String(format: "%7.1f", (t2 - t1) * 1000))"
                                 + "  stop=\(String(format: "%7.1f", (t3 - t2) * 1000))"
                                 + "  total=\(String(format: "%7.1f", (t3 - t0) * 1000)) ms  \(dims)")
                }
            }
        }

        // ③ 各条完整路径（含各自的 shareableContent 开销）。
        for i in 0..<iterations {
            let t = CACurrentMediaTime()
            let r = try? await captureAllScreensViaStream()
            lines.append("  path stream[\(i)]   \(elapsed(t)) ms  ok=\(r?.count ?? -1)")
        }
        for i in 0..<iterations {
            let t = CACurrentMediaTime()
            let r = try? await captureAllScreensViaCLI()
            lines.append("  path cli[\(i)]      \(elapsed(t)) ms  ok=\(r?.count ?? -1)")
        }
        for i in 0..<iterations {
            let t = CACurrentMediaTime()
            let r = try? await captureAllScreensViaSCK()
            lines.append("  path sck[\(i)]      \(elapsed(t)) ms  ok=\(r?.count ?? -1)")
        }
        // 默认路径 = 真正的产品路径（stream → cli → sck 依次降级）。
        for i in 0..<iterations {
            let t = CACurrentMediaTime()
            let r = try? await captureAllScreens()
            lines.append("  path DEFAULT[\(i)]  \(elapsed(t)) ms  ok=\(r?.count ?? -1)")
        }
        return lines.joined(separator: "\n")
    }
}
