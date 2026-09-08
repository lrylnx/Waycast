import Cocoa
import Carbon.HIToolbox
import SwiftUI

/// Borderless windows can't become key by default — this one can, so it
/// receives mouse-downs immediately and gets keyboard events (⌘Z, Esc, text input).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // ⌘W (menu performClose:) must not tear down a screenshot session
    // out from under the controller; Esc / the X button are the exits.
    override func performClose(_ sender: Any?) {}
}

/// Orchestrates one screenshot session: capture -> overlay -> toolbar -> output.
@MainActor
final class ScreenshotController: NSObject {
    enum Mode { case annotate, pin }

    private var overlayWindow: NSWindow?
    private var overlayView: ScreenshotOverlayView?
    private var toolbar: AnnotationToolbar?
    private var mode: Mode = .annotate
    private var screen: NSScreen?
    private var desktopImage: CGImage?
    private var pixelatedCache: CGImage?
    private var keyRetryWork: DispatchWorkItem?
    private var escMonitor: Any?

    func start(mode: Mode) {
        guard overlayWindow == nil else { return }   // already running
        self.mode = mode

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }

        let screen = ScreenUtils.screenContainingMouse() ?? NSScreen.main
        guard let screen else { return }
        self.screen = screen

        ScreenCapture.capture(screen: screen) { [weak self] image in
            guard let self, let image else { return }
            self.beginSession(image: image, screen: screen)
        }
    }

    private func beginSession(image: CGImage, screen: NSScreen) {
        desktopImage = image
        pixelatedCache = nil

        let frame = screen.frame
        let window = OverlayWindow(contentRect: frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false

        let view = ScreenshotOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.model.desktopImage = image
        view.model.desktopScale = screen.backingScaleFactor
        view.model.overlayView = view
        view.onSelectionChanged = { [weak self] _ in self?.positionToolbar() }
        view.onFinish = { [weak self] in self?.cancel() }
        view.onDoubleClick = { [weak self] in
            guard let self, let model = self.overlayView?.model else { return }
            self.overlayView?.commitTextEdit()
            if self.mode == .pin {
                self.pinSelection(model: model)
            } else {
                self.confirm(model: model)
            }
        }
        view.onSelectionSettled = { [weak self] in
            // Pin mode: releasing the mouse after a drag pins immediately.
            guard let self, self.mode == .pin, let model = self.overlayView?.model else { return }
            self.pinSelection(model: model)
        }
        // Right-click anywhere = escape hatch, works even without keyboard focus.
        view.onCancelByRightClick = { [weak self] in self?.cancel() }

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        overlayWindow = window
        overlayView = view

        if mode == .annotate {
            buildToolbar(for: view.model, in: view)
        } else {
            // Pin mode: select a region, then double-click or press Enter to pin.
            Toast.show("框选要贴图的区域，双击或回车确认")
        }

        // A hotkey pressed while the status menu is still open runs beginSession
        // INSIDE the menu's nested tracking loop, so makeKeyAndOrderFront silently
        // fails — the overlay shows but never becomes key, and Esc/⌘Z (which arrive
        // through keyDown) are lost. That left a full-screen screenSaver-level
        // window the user could not dismiss. Arm a watchdog that keeps re-asserting
        // key focus until the menu releases it, and tears the session down if it
        // never can, so the screen is never left frozen.
        armKeyWindowWatchdog(for: window)
        installEscFallback()
    }

    /// Retry activation until the overlay is actually key; give up (and tear down)
    /// rather than strand the user behind an unfocusable full-screen window.
    private func armKeyWindowWatchdog(for window: NSWindow, attempts: Int = 12) {
        keyRetryWork?.cancel()
        guard attempts > 0 else {
            // Still not key after ~1.8s of retries — the session is unusable.
            // Close it so the desktop is interactive again.
            teardown()
            Toast.show("截图已取消，请稍后重试")
            return
        }
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.overlayWindow === window else { return }
            if window.isKeyWindow { return }        // focus acquired, done
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.overlayView)
            self.armKeyWindowWatchdog(for: window, attempts: attempts - 1)
        }
        keyRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Belt-and-suspenders Esc: a local monitor fires for this app's key events
    /// regardless of which window is key, so Esc always ends the session.
    private func installEscFallback() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.overlayWindow != nil else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.teardown()
                return nil
            }
            return event
        }
    }

    // MARK: - Toolbar (subview of the overlay, like SnapPin)
    //
    // Hosting the toolbar INSIDE the key overlay window — instead of a
    // separate non-key NSPanel — is what makes the FIRST click on every
    // button land. A panel that can't become key swallows the initial
    // mouse-down into a (failed) key-window attempt.

    private func buildToolbar(for model: ScreenshotModel, in overlay: ScreenshotOverlayView) {
        let actions = ScreenshotActions(
            selectTool: { [weak self] tool in
                // Tapping the already-active tool toggles it off (back to the
                // move/select tool).
                model.tool = (model.tool == tool) ? .select : tool
                self?.overlayView?.commitTextEdit()
                self?.overlayView?.needsDisplay = true
            },
            selectColor: { model.color = $0 },
            pickCustomColor: { [weak self] in self?.presentColorPanel() },
            undo: { [weak self] in
                self?.overlayView?.commitTextEdit()
                model.undo()
            },
            ocr: { [weak self] in self?.runOCR(model: model) },
            save: { [weak self] in self?.saveSelection(model: model) },
            pin: { [weak self] in self?.pinSelection(model: model) },
            cancel: { [weak self] in self?.cancel() },
            confirm: { [weak self] in
                self?.overlayView?.commitTextEdit()
                self?.confirm(model: model)
            }
        )
        let bar = AnnotationToolbar(model: model, actions: actions)
        // Hidden until a real selection exists: clicking around before
        // dragging a box must not show (or misposition) the toolbar.
        bar.isHidden = true
        overlay.addSubview(bar)
        toolbar = bar
    }

    func positionToolbar() {
        guard let overlay = overlayView, let bar = toolbar else { return }
        // Hidden before a real box exists AND while a drag is in progress, so
        // the toolbar never chases the selection mid-drag.
        let show = overlay.model.hasSelection && !overlay.isCreatingSelection
        bar.isHidden = !show
        guard show else { return }
        let sel = overlay.model.selection
        let size = bar.frame.size
        // View is flipped: y grows downward. Prefer just below the selection,
        // then above, clamped inside the screen bounds.
        var y = sel.maxY + 10
        if y + size.height > overlay.bounds.maxY - 2 {
            y = max(2, sel.minY - 10 - size.height)
        }
        var x = sel.maxX - size.width
        x = max(2, min(x, overlay.bounds.maxX - size.width - 2))
        bar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    // MARK: - Compositing

    /// Render selection + annotations into a pixel-accurate image identical
    /// to what the overlay preview shows.
    private func compositedImage(_ model: ScreenshotModel) -> CGImage? {
        guard let desktop = desktopImage, model.hasSelection else { return nil }
        let scale = model.desktopScale
        let Wpx = desktop.width, Hpx = desktop.height
        let Wpt = CGFloat(Wpx) / scale, Hpt = CGFloat(Hpx) / scale
        let sel = model.selection

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Wpx, height: Hpx,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Reproduce the flipped view's drawing environment: top-down points CTM
        // + a flipped NSGraphicsContext, so output matches the preview exactly.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: Hpt)
        ctx.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSImage(cgImage: desktop, size: NSSize(width: Wpt, height: Hpt))
            .draw(in: CGRect(x: 0, y: 0, width: Wpt, height: Hpt))

        let rc = AnnotationRenderer.Context(
            desktop: desktop,
            pixelated: pixelatedCache ?? {
                let p = ImageProcessor.pixelate(desktop, blockSize: 12 * scale)
                pixelatedCache = p
                return p
            }(),
            viewSize: NSSize(width: Wpt, height: Hpt))
        ctx.saveGState()
        ctx.clip(to: sel)
        for a in model.annotations { AnnotationRenderer.draw(a, ctx: ctx, rc: rc) }
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        guard let full = ctx.makeImage() else { return nil }
        let cropRect = CGRect(x: (sel.minX * scale).rounded(),
                              y: (sel.minY * scale).rounded(),
                              width: (sel.width * scale).rounded(),
                              height: (sel.height * scale).rounded())
        return ImageProcessor.crop(full, to: cropRect) ?? full
    }

    private func presentColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.isContinuous = true
        // Keep it above the screen-saver-level overlay.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.orderFront(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(colorPanelClosed(_:)),
                                               name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        overlayView?.model.color = sender.color
    }

    @objc private func colorPanelClosed(_ note: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification,
                                                  object: nil)
        overlayWindow?.makeKeyAndOrderFront(nil)
        overlayWindow?.makeFirstResponder(overlayView)
    }

    // MARK: - Actions

    private func confirm(model: ScreenshotModel) {
        guard let img = compositedImage(model) else { cancel(); return }
        ImageProcessor.copyToPasteboard(img)
        teardown()
        Toast.show("已复制到剪贴板")
    }

    private func saveSelection(model: ScreenshotModel) {
        guard let img = compositedImage(model) else { return }
        let name = "截图 \(Self.dateFormatter.string(from: Date())).png"
        // End the session FIRST (SnapPin flow): the screen-saver-level overlay
        // would otherwise sit above the save panel and swallow it.
        teardown()
        ImageProcessor.saveWithPanel(img, defaultName: name)
    }

    private func pinSelection(model: ScreenshotModel) {
        guard let img = compositedImage(model) else { return }
        let sel = model.selection
        teardown()
        PinWindowManager.shared.pin(image: img, viewRect: sel, screen: screen)
    }

    private func runOCR(model: ScreenshotModel) {
        guard model.hasSelection, let img = compositedImage(model) else { return }
        // SnapPin flow: tear down the overlay immediately, then recognize.
        // The screenSaver-level overlay was covering the result window, which
        // is why OCR "did nothing" from the user's perspective.
        teardown()
        ImageProcessor.recognizeText(in: img) { text in
            Task { @MainActor in
                if text.isEmpty {
                    Toast.show("未识别到文字")
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    OCRResultWindow.shared.show(text: text)
                }
            }
        }
    }

    func cancel() {
        teardown()
    }

    private func teardown() {
        keyRetryWork?.cancel()
        keyRetryWork = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        toolbar?.removeFromSuperview()
        toolbar = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil
        desktopImage = nil
        pixelatedCache = nil
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}
