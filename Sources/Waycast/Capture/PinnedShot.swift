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
    /// 悬停工具条的内容（OCR / 关闭）。
    private let hoverBar: NSStackView
    /// 工具条的外壳：macOS 26+ 是液态玻璃，旧系统是半透明色块。
    /// lazy：尺寸取 fittingSize，必须在按钮都加进去之后才算得准。
    private lazy var hoverChrome: NSView = GlassBackdrop.wrap(hoverBar, cornerRadius: 10)
    private var hoverArea: NSTrackingArea?

    init(frame: NSRect, image: CGImage) {
        self.image = image
        self.hoverBar = NSStackView(views: [])
        super.init(frame: frame)
        wantsLayer = true

        let ocr = IconButton(frame: .zero)
        // 和截图工具栏同一个自绘图标（圆角框里写 OCR），14×13，与旁边 12pt 的
        // xmark 视觉重量对齐。
        ocr.image = CaptureSelectionView.ocrGlyphIcon(height: 13)
        ocr.imageScaling = .scaleProportionallyDown
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
        hoverBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        hoverBar.addArrangedSubview(ocr)
        hoverBar.addArrangedSubview(close)
        // 换行工具条底色：macOS 26+ 原生液态玻璃（会实时折射它下面的截图）。
        addSubview(hoverChrome)
        let barSize = hoverChrome.frame.size
        hoverChrome.setFrameOrigin(NSPoint(x: bounds.maxX - barSize.width - 6,
                                           y: bounds.maxY - barSize.height - 6))
        hoverChrome.isHidden = true
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

    override func mouseEntered(with event: NSEvent) { hoverChrome.isHidden = false }
    override func mouseExited(with event: NSEvent) { hoverChrome.isHidden = true }

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
            // 识别与展示都在结果窗口里（它显示「正在识别…」，并支持换语言重算）。
            OcrResultWindowController.shared.show(image: image,
                                                 sourceName: "贴图",
                                                 near: panel.frame)
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
