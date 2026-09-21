//
//  PinnedShot.swift
//  Waycast
//
//  钉在桌面：把截图（含标注）以无边框浮动小窗钉在原位置。
//  - 可拖动（拖图即移动窗口）
//  - 悬停出现小工具条：OCR / 关闭
//  - 右键直接关闭
//  - 支持同时钉多张
//

import AppKit

// MARK: - Pinned shot window (one per pinned screenshot)

final class PinnedShotPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Content view (image + hover bar + right-click close)

@MainActor
final class PinnedShotView: NSView {
    var onClose: (() -> Void)?
    var onOCR: (() -> Void)?

    private let image: CGImage
    private let hoverBar: NSStackView
    private var hoverArea: NSTrackingArea?

    init(frame: NSRect, image: CGImage) {
        self.image = image
        self.hoverBar = NSStackView(views: [])
        super.init(frame: frame)
        wantsLayer = true

        let ocr = IconButton(frame: .zero)
        ocr.image = NSImage(systemSymbolName: "doc.text.viewfinder", accessibilityDescription: "OCR 文字识别")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        ocr.isBordered = false
        ocr.toolTip = "OCR 文字识别"
        ocr.setAccessibilityLabel("OCR 文字识别")
        ocr.contentTintColor = .labelColor
        let ocrTrampoline = ClosureTarget(handler: { [weak self] in self?.onOCR?() })
        objc_setAssociatedObject(ocr, "action.trampoline", ocrTrampoline, .OBJC_ASSOCIATION_RETAIN)
        ocr.target = ocrTrampoline
        ocr.action = #selector(ClosureTarget.fire)

        let close = IconButton(frame: .zero)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        close.isBordered = false
        close.toolTip = "关闭"
        close.setAccessibilityLabel("关闭")
        close.contentTintColor = .systemRed
        let closeTrampoline = ClosureTarget(handler: { [weak self] in self?.onClose?() })
        objc_setAssociatedObject(close, "action.trampoline", closeTrampoline, .OBJC_ASSOCIATION_RETAIN)
        close.target = closeTrampoline
        close.action = #selector(ClosureTarget.fire)

        for button in [ocr, close] {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
        }

        hoverBar.orientation = .horizontal
        hoverBar.spacing = 2
        hoverBar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        hoverBar.addArrangedSubview(ocr)
        hoverBar.addArrangedSubview(close)
        hoverBar.wantsLayer = true
        hoverBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        hoverBar.layer?.cornerRadius = 7
        hoverBar.layer?.borderWidth = 0.5
        hoverBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        hoverBar.layer?.shadowColor = NSColor.black.cgColor
        hoverBar.layer?.shadowOpacity = 0.3
        hoverBar.layer?.shadowRadius = 6
        hoverBar.layer?.shadowOffset = NSSize(width: 0, height: -2)
        addSubview(hoverBar)
        let barSize = hoverBar.fittingSize
        hoverBar.setFrameSize(barSize)
        hoverBar.setFrameOrigin(NSPoint(x: bounds.maxX - barSize.width - 6,
                                        y: bounds.maxY - barSize.height - 6))
        hoverBar.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hoverBar.isHidden = false }
    override func mouseExited(with event: NSEvent) { hoverBar.isHidden = true }

    /// Right-click closes the pinned shot.
    override func rightMouseDown(with event: NSEvent) { onClose?() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
    }
}

// MARK: - Controller

@MainActor
final class PinnedShotController: NSObject {
    static let shared = PinnedShotController()
    private var pins: [PinnedShotPanel] = []

    /// Pins `image` at `screenRect` (global, AppKit bottom-left origin) —
    /// the exact spot the selection was made, so nothing appears to jump.
    func pin(image: CGImage, screenRect: NSRect) {
        let rect = screenRect.integral
        let panel = PinnedShotPanel(contentRect: rect)
        let content = PinnedShotView(frame: NSRect(origin: .zero, size: rect.size), image: image)
        content.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.close(panel)
        }
        content.onOCR = { [weak panel, image] in
            guard let panel else { return }
            let frame = panel.frame
            Task { @MainActor in
                let text = await CaptureController.recognizeText(in: image)
                guard !text.isEmpty else {
                    Toast.show("未识别到文字")
                    return
                }
                OCRResultWindowController.shared.show(text: text, near: frame)
            }
        }
        panel.contentView = content
        // Appear without animation: order front while transparent, then flip.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.alphaValue = 1
        pins.append(panel)
    }

    private func close(_ panel: PinnedShotPanel) {
        panel.orderOut(nil)
        panel.contentView = nil
        pins.removeAll { $0 === panel }
    }

    /// Closes every pinned shot (kept for future menu integration).
    func closeAll() {
        for panel in pins { close(panel) }
    }
}
