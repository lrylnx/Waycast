import Cocoa
import Carbon.HIToolbox

/// A borderless floating window that "pins" a captured image onto the screen.
/// Draggable, scroll-to-zoom, double-click or Esc to dismiss.
final class PinWindow: NSWindow {
    private let image: CGImage
    private var baseSize: NSSize

    init(image: CGImage, contentSize: NSSize) {
        self.image = image
        self.baseSize = contentSize
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.borderless, .resizable],
                   backing: .buffered, defer: false)
        // Programmatic windows default to isReleasedWhenClosed=true; combined
        // with our strong refs that over-releases on close -> objc_release
        // SIGSEGV. We own the lifetime (PinWindowManager parks closed pins).
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        ignoresMouseEvents = false

        let view = PinImageView(image: image)
        view.onDismiss = { [weak self] in self?.dismissPin() }
        view.onZoom = { [weak self] scale in self?.applyZoom(scale) }
        contentView = view
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 6
        contentView?.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }

    /// Hide instead of close(): NSWindow.close() runs a full teardown that,
    /// for borderless windows released from menu-tracking / queue-drain
    /// contexts, was crashing the app (objc_release SIGSEGV). orderOut just
    /// hides; the manager parks the window so it never deallocates.
    fileprivate func dismissPin() {
        PinWindowManager.shared.windowClosed(self)
        orderOut(nil)
    }

    private func applyZoom(_ scale: CGFloat) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var newFrame = frame
        newFrame.size.width = max(40, frame.width * scale)
        newFrame.size.height = max(40, frame.height * scale)
        newFrame.origin = CGPoint(x: center.x - newFrame.width / 2,
                                  y: center.y - newFrame.height / 2)
        setFrame(newFrame, display: true, animate: false)
    }

    override func close() {
        PinWindowManager.shared.windowClosed(self)
        super.close()
    }
}

final class PinImageView: NSView {
    let image: CGImage
    var onDismiss: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        let scale: CGFloat = event.scrollingDeltaY > 0 ? 1.08 : (event.scrollingDeltaY < 0 ? 0.92 : 1)
        onZoom?(scale)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDismiss?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制图片", action: #selector(copyImage), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let closeItem = NSMenuItem(title: "关闭贴图", action: #selector(dismiss), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImage() {
        guard let data = ImageProcessor.pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }

    @objc private func dismiss() {
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onDismiss?() }
    }

    override var acceptsFirstResponder: Bool { true }
}

/// Keeps track of all pinned windows.
final class PinWindowManager {
    static let shared = PinWindowManager()
    private var windows: [PinWindow] = []
    /// Closed pins are parked here (strong refs) and NEVER deallocated.
    /// The 17:47 crash was objc_release SIGSEGV inside _swift_release_dealloc
    /// triggered when a main-queue async block dropped the last ref to an
    /// NSWindow during queue drain — freeing a borderless window there is
    /// unsafe. Parking keeps every pin alive forever; the count is bounded by
    /// how many pins a user creates in a session, so the memory is negligible.
    private var parked: [PinWindow] = []

    func pin(image: CGImage, viewRect: CGRect, screen: NSScreen?) {
        let scale = screen?.backingScaleFactor ?? 2
        let size = NSSize(width: max(60, viewRect.width), height: max(60, viewRect.height))
        let win = PinWindow(image: image, contentSize: size)

        // Position at the original selection location.
        if let screen {
            let originY = screen.frame.maxY - viewRect.maxY
            win.setFrameOrigin(NSPoint(x: screen.frame.minX + viewRect.minX, y: originY))
        } else {
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        win.contentView?.window?.makeFirstResponder(win.contentView)
        _ = scale
        windows.append(win)
    }

    func windowClosed(_ win: PinWindow) {
        windows.removeAll { $0 === win }
        parked.append(win)   // keep alive; never dealloc during event/drain
    }
}
