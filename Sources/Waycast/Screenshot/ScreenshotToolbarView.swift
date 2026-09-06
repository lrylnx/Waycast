import Cocoa
import SwiftUI
import Combine

/// Callbacks from toolbar to the controller.
struct ScreenshotActions {
    var selectTool: (AnnotationTool) -> Void
    var selectColor: (NSColor) -> Void
    var pickCustomColor: () -> Void
    var undo: () -> Void
    var ocr: () -> Void
    var save: () -> Void
    var pin: () -> Void
    var cancel: () -> Void
    var confirm: () -> Void
}

/// Floating annotation toolbar — pure AppKit (SnapPin parity).
/// A SwiftUI hosting view inside the screen-saver-level overlay made every
/// button feel laggy (state updates re-render the hosting tree and dirty the
/// full-screen redraw); plain NSButtons in the key window respond instantly.
final class AnnotationToolbar: NSView {
    private let model: ScreenshotModel
    private let actions: ScreenshotActions
    private var toolButtons: [ToolButton] = []
    private var undoButton: ToolButton!
    private var swatchButton: ColorSwatchButton!
    private var sizeLabel: NSTextField!
    private var cancellables = Set<AnyCancellable>()
    private var colorPopover: NSPopover?

    private let buttonW: CGFloat = 30
    private let buttonH: CGFloat = 30

    init(model: ScreenshotModel, actions: ScreenshotActions) {
        self.model = model
        self.actions = actions
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 44))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor

        for t in [AnnotationTool.select, .rect, .pen, .arrow, .text, .mosaic] {
            let b = ToolButton(symbol: t.symbol, tooltip: t.label + "（滚轮调节大小）", tool: t)
            switch t {
            case .select: b.setGlyph(ToolbarGlyphs.move())
            case .mosaic: b.setGlyph(ToolbarGlyphs.mosaic())
            case .pen:    b.setGlyph(ToolbarGlyphs.pen())
            default:
                if let letter = t.letter { b.setLetter(letter) }
            }
            b.target = self
            b.action = #selector(toolClicked(_:))
            addSubview(b)
            toolButtons.append(b)
        }
        addSeparator()

        undoButton = ToolButton(symbol: "arrow.uturn.backward", tooltip: "撤销上一笔 (⌘Z)", tool: nil)
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        addSubview(undoButton)

        swatchButton = ColorSwatchButton(model: model)
        swatchButton.toolTip = "颜色（点击选择）"
        swatchButton.target = self
        swatchButton.action = #selector(colorClicked)
        addSubview(swatchButton)

        sizeLabel = NSTextField(labelWithString: "4")
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = NSColor(white: 0.75, alpha: 1)
        sizeLabel.alignment = .center
        // Fixed width that always fits two digits (10-40); auto-sizing clipped
        // the second digit once the value grew past 9.
        sizeLabel.frame = NSRect(x: 0, y: 0, width: 24, height: 14)
        addSubview(sizeLabel)
        addSeparator()

        let acts: [(String, String, Selector, NSColor)] = [
            ("text.viewfinder", "OCR 识别文字", #selector(ocrClicked), .white),
            ("square.and.arrow.down", "保存 (⌘S)", #selector(saveClicked), .white),
            ("pin", "贴在屏幕上", #selector(pinClicked), .white),
            ("xmark", "取消 (Esc)", #selector(cancelClicked), .systemRed),
            ("checkmark", "完成并复制到剪贴板 (⌘C)", #selector(confirmClicked), .systemGreen),
        ]
        for def in acts {
            let b = ToolButton(symbol: def.0, tooltip: def.1, tool: nil, tint: def.3)
            if def.0 == "square.and.arrow.down" { b.setGlyph(ToolbarGlyphs.save()) }
            b.target = self
            b.action = def.2
            addSubview(b)
        }

        relayout()
        subscribe()
        refreshTools()
        refreshSize()
        undoButton.isEnabled = !model.annotations.isEmpty
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addSeparator() {
        addSubview(SeparatorView(frame: .zero))
    }

    /// Subviews are in insertion order; lay them out left to right.
    private func relayout() {
        var x: CGFloat = 6
        let h = bounds.height
        for v in subviews {
            if v is SeparatorView {
                v.frame = NSRect(x: x, y: (h - 16) / 2, width: 1, height: 16)
                x += 1 + 5
            } else if v === sizeLabel {
                v.setFrameOrigin(NSPoint(x: x, y: (h - v.frame.height) / 2))
                x += v.frame.width + 4
            } else {
                v.frame = NSRect(x: x, y: (h - buttonH) / 2, width: buttonW, height: buttonH)
                x += buttonW + 2
            }
        }
        frame.size.width = x + 2
    }

    private func subscribe() {
        model.$tool.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTools() }
            .store(in: &cancellables)
        model.$color.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.swatchButton.needsDisplay = true }
            .store(in: &cancellables)
        model.$annotations.receive(on: RunLoop.main)
            .sink { [weak self] a in self?.undoButton.isEnabled = !a.isEmpty }
            .store(in: &cancellables)
        model.$lineWidth.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSize() }
            .store(in: &cancellables)
        model.$fontSize.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSize() }
            .store(in: &cancellables)
    }

    private func refreshTools() {
        for b in toolButtons { b.isOn = (b.tool == model.tool) }
        refreshSize()
    }

    private func refreshSize() {
        sizeLabel.stringValue = "\(Int(model.currentSizeValue()))"
    }

    // MARK: - Actions

    @objc private func toolClicked(_ sender: ToolButton) {
        guard let t = sender.tool else { return }
        actions.selectTool(t)
    }
    @objc private func undoClicked() { actions.undo() }
    @objc private func ocrClicked() { actions.ocr() }
    @objc private func saveClicked() { actions.save() }
    @objc private func pinClicked() { actions.pin() }
    @objc private func cancelClicked() { actions.cancel() }
    @objc private func confirmClicked() { actions.confirm() }

    @objc private func colorClicked(_ sender: NSView) {
        if let p = colorPopover, p.isShown { p.performClose(nil); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: ColorPaletteView(model: model,
                                                                                        actions: actions))
        popover.contentSize = NSSize(width: 220, height: 168)
        colorPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

// MARK: - Buttons

/// Icon button with an "on" highlight for the selected tool.
final class ToolButton: NSButton {
    let tool: AnnotationTool?
    var isOn: Bool = false { didSet { needsDisplay = true } }

    init(symbol: String, tooltip: String, tool: AnnotationTool?, tint: NSColor = .white) {
        self.tool = tool
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        toolTip = tooltip
        setButtonType(.momentaryChange)
        focusRingType = .none
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        contentTintColor = tint
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Replace the SF Symbol with a plain letter glyph (e.g. "T" for text —
    /// character.cursor.ibeam read as "AI" at this size).
    func setLetter(_ s: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let size = str.size()
        let img = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
        img.lockFocus()
        str.draw(at: .zero)
        img.unlockFocus()
        img.isTemplate = true   // keeps contentTintColor working
        image = img
    }

    /// Replace the SF Symbol with a custom-drawn template glyph.
    func setGlyph(_ img: NSImage) {
        img.isTemplate = true
        image = img
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Custom glyphs
//
// SF Symbols that read poorly at 15pt in the toolbar ("hand" rendered as a
// blank blue blob, "mosaic" not looking like a mosaic, the save symbol
// sitting off-center) are replaced with hand-drawn 17x17 template images,
// which tint and center exactly like the rest of the bar.

enum ToolbarGlyphs {
    private static let canvas: CGFloat = 17

    /// Four-way move arrow (pan / move selection).
    static func move() -> NSImage {
        let img = NSImage(size: NSSize(width: canvas, height: canvas))
        img.lockFocus()
        let c = canvas / 2
        let line = NSBezierPath()
        line.lineWidth = 1.6
        line.lineCapStyle = .round
        // cross
        line.move(to: NSPoint(x: c, y: 2)); line.line(to: NSPoint(x: c, y: canvas - 2))
        line.move(to: NSPoint(x: 2, y: c)); line.line(to: NSPoint(x: canvas - 2, y: c))
        NSColor.black.setStroke()
        line.stroke()
        // arrow heads: up, down, left, right
        func head(_ tip: NSPoint, _ dir: CGVector) {
            let s: CGFloat = 3.2
            let p = NSBezierPath()
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            // perpendicular
            let perp = CGVector(dx: -dir.dy, dy: dir.dx)
            let base = NSPoint(x: tip.x - dir.dx * s, y: tip.y - dir.dy * s)
            p.move(to: NSPoint(x: base.x + perp.dx * s * 0.75, y: base.y + perp.dy * s * 0.75))
            p.line(to: tip)
            p.line(to: NSPoint(x: base.x - perp.dx * s * 0.75, y: base.y - perp.dy * s * 0.75))
            NSColor.black.setStroke()
            p.stroke()
        }
        head(NSPoint(x: c, y: canvas - 1.5), CGVector(dx: 0, dy: 1))
        head(NSPoint(x: c, y: 1.5), CGVector(dx: 0, dy: -1))
        head(NSPoint(x: canvas - 1.5, y: c), CGVector(dx: 1, dy: 0))
        head(NSPoint(x: 1.5, y: c), CGVector(dx: -1, dy: 0))
        img.unlockFocus()
        return img
    }

    /// Checkerboard patch — unmistakably "mosaic / pixelate". Drawn slightly
    /// smaller than the canvas so it doesn't overpower neighboring glyphs.
    static func mosaic() -> NSImage {
        let img = NSImage(size: NSSize(width: canvas, height: canvas))
        img.lockFocus()
        let board = canvas - 3          // 1.5pt margin on each side
        let cell = board / 3
        let ox = (canvas - board) / 2
        NSColor.black.setFill()
        // 5 filled squares of a 3x3 board (corners + center) = classic mosaic
        for (col, row) in [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)] {
            let r = NSRect(x: ox + CGFloat(col) * cell, y: ox + CGFloat(row) * cell,
                           width: cell, height: cell)
                .insetBy(dx: 0.3, dy: 0.3)
            NSBezierPath(rect: r).fill()
        }
        // outline the empty cells so the board reads as a grid
        NSColor.black.withAlphaComponent(0.55).setStroke()
        for (col, row) in [(1, 0), (0, 1), (2, 1), (1, 2)] {
            let r = NSRect(x: ox + CGFloat(col) * cell, y: ox + CGFloat(row) * cell,
                           width: cell, height: cell)
                .insetBy(dx: 0.45, dy: 0.45)
            let p = NSBezierPath(rect: r)
            p.lineWidth = 0.7
            p.stroke()
        }
        img.unlockFocus()
        return img
    }

    /// Short pencil tilted 45° (tip bottom-left): point + body + eraser band,
    /// with transparent gaps cut out so it reads as a pencil, not a blob.
    static func pen() -> NSImage {
        let img = NSImage(size: NSSize(width: canvas, height: canvas))
        img.lockFocus()
        let d = CGVector(dx: 0.7071, dy: 0.7071)      // axis: bottom-left -> top-right
        let perp = CGVector(dx: -0.7071, dy: 0.7071)  // half-width direction
        let w: CGFloat = 2.4
        let tip = NSPoint(x: 3.0, y: 3.0)
        func along(_ t: CGFloat) -> NSPoint {
            NSPoint(x: tip.x + d.dx * t, y: tip.y + d.dy * t)
        }
        func at(_ p: NSPoint, _ hw: CGFloat) -> (NSPoint, NSPoint) {
            (NSPoint(x: p.x + perp.dx * hw, y: p.y + perp.dy * hw),
             NSPoint(x: p.x - perp.dx * hw, y: p.y - perp.dy * hw))
        }
        let bA = along(4.2)   // tip base
        let bB = along(12.4)  // body end / eraser start
        let bC = along(14.6)  // eraser end

        let body = NSBezierPath()
        let (t1, t2) = at(bA, w)
        let (e1, e2) = at(bC, w)
        body.move(to: tip)
        body.line(to: t1)
        body.line(to: e1)
        body.line(to: e2)
        body.line(to: t2)
        body.close()
        NSColor.black.setFill()
        body.fill()

        // Cut a transparent gap separating the eraser band from the body.
        NSGraphicsContext.current!.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        for seam in [bB] {
            let (s1, s2) = at(seam, w + 1)
            let p = NSBezierPath()
            p.move(to: s1); p.line(to: s2)
            p.lineWidth = 1.3
            p.stroke()
        }
        NSGraphicsContext.current!.compositingOperation = .sourceOver
        img.unlockFocus()
        return img
    }

    /// Download arrow into an open tray — "save", drawn centered on the canvas.
    static func save() -> NSImage {
        let img = NSImage(size: NSSize(width: canvas, height: canvas))
        img.lockFocus()
        let c = canvas / 2
        NSColor.black.set()
        let shaft = NSBezierPath()
        shaft.lineWidth = 1.7
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: c, y: canvas - 2.5))
        shaft.line(to: NSPoint(x: c, y: 7.5))
        shaft.stroke()
        let head = NSBezierPath()
        head.lineWidth = 1.7
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.move(to: NSPoint(x: c - 3.2, y: 10.2))
        head.line(to: NSPoint(x: c, y: 6.8))
        head.line(to: NSPoint(x: c + 3.2, y: 10.2))
        head.stroke()
        let tray = NSBezierPath()
        tray.lineWidth = 1.7
        tray.lineCapStyle = .round
        tray.lineJoinStyle = .round
        tray.move(to: NSPoint(x: 2.5, y: 4.5))
        tray.line(to: NSPoint(x: 2.5, y: 2))
        tray.line(to: NSPoint(x: canvas - 2.5, y: 2))
        tray.line(to: NSPoint(x: canvas - 2.5, y: 4.5))
        tray.stroke()
        img.unlockFocus()
        return img
    }
}

/// Current-color circle; click opens the palette popover.
final class ColorSwatchButton: NSButton {
    private weak var model: ScreenshotModel?

    init(model: ScreenshotModel) {
        self.model = model
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.28, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()
        (model?.color ?? .systemRed).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8)).fill()
        NSColor(white: 1, alpha: 0.45).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        ring.lineWidth = 1
        ring.stroke()
    }
}

final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.15).setFill()
        bounds.fill()
    }
}

// MARK: - Color palette (popover content)

/// Palette shown in the color button's popover: swatches + custom color.
struct ColorPaletteView: View {
    @ObservedObject var model: ScreenshotModel
    var actions: ScreenshotActions
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 30), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("颜色")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(model.palette.enumerated()), id: \.offset) { _, c in
                    Button(action: {
                        actions.selectColor(c)
                        dismiss()
                    }) {
                        Circle()
                            .fill(Color(c))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().strokeBorder(
                                    model.color == c ? Color.accentColor : Color.white.opacity(0.4),
                                    lineWidth: model.color == c ? 3 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(c.displayName)
                }
            }
            Divider()
            Button("自定义颜色…") {
                dismiss()
                actions.pickCustomColor()
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 220)
    }
}

extension NSColor {
    var displayName: String {
        switch self {
        case NSColor.systemRed: return "红色"
        case NSColor.systemOrange: return "橙色"
        case NSColor.systemYellow: return "黄色"
        case NSColor.systemGreen: return "绿色"
        case NSColor.systemBlue: return "蓝色"
        case NSColor.systemPurple: return "紫色"
        case NSColor.black: return "黑色"
        case NSColor.white: return "白色"
        default: return "自定义"
        }
    }
}
