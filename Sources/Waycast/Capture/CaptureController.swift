//
//  CaptureController.swift
//  Waycast
//
//  Orchestrates one frozen-capture session (ported from Mio's
//  CaptureController/SelectionPresenter/AreaSelectionView, GPL-3.0, adapted
//  to Swift 5.9 / macOS 14):
//
//  hotkey → freeze all displays → per-display overlay showing the still
//  frame → drag a region (or click a window) → annotate (pen / text / undo)
//  → action bar (复制/OCR/保存) → compose annotations onto the crop →
//  clipboard / Vision OCR / save panel.
//
//  Esc / right-click cancels at any point.
//

import AppKit
import Vision

// MARK: - Closure trampoline for NSButton

final class ClosureTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

// MARK: - Icon button (SF Symbol, hover highlight)

/// Square icon button for the capture toolbar, like modern screenshot tools:
/// transparent by default, subtle highlight on hover, accent background when
/// selected (active tool).
final class IconButton: NSButton {
    var isSelectedStyle = false { didSet { updateBackground() } }
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateBackground() }

    private func updateBackground() {
        if isSelectedStyle {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
        } else if hovering && isEnabled {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - Annotation model

struct PenStroke {
    var points: [NSPoint]
    var color: NSColor
    var width: CGFloat
}

struct TextAnnotation {
    /// Bottom-left of the text block, in view (bottom-left origin) coordinates.
    var point: NSPoint
    var text: String
    var fontSize: CGFloat
    var color: NSColor
}

struct ArrowAnnotation {
    var start: NSPoint
    var end: NSPoint
    var color: NSColor
    var width: CGFloat
}

enum CaptureAnnotation {
    case stroke(PenStroke)
    case text(TextAnnotation)
    case arrow(ArrowAnnotation)
}

// MARK: - Non-activating overlay panel

final class CapturePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        // Tahoe plays a zoom animation when a new window is ordered front.
        // Panels are pooled and never re-ordered from scratch (see
        // CaptureController.panelPool), this is a second line of defense.
        animationBehavior = .none
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Inline text editor

/// Transparent, borderless text editor for on-screenshot typing.
/// Enter commits; Shift+Enter inserts a newline; Esc discards.
final class AnnotationTextView: NSTextView {
    /// Top-left anchor (view coords) the editor grows downward from.
    var anchorTop: NSPoint = .zero
    var onCommit: (() -> Void)?
    var onDiscard: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        growToFit()
    }

    override func insertNewline(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            super.insertNewline(sender)
        } else {
            onCommit?()
        }
    }

    override func cancelOperation(_ sender: Any?) { onDiscard?() }

    private func growToFit() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let height = max(28, layout.usedRect(for: container).height + 8)
        setFrameOrigin(NSPoint(x: anchorTop.x, y: anchorTop.y - height))
        setFrameSize(NSSize(width: frame.width, height: height))
    }
}

// MARK: - Selection surface (one per frozen display)

@MainActor
final class CaptureSelectionView: NSView {
    enum Phase { case idle, dragging, pendingAction }
    enum Tool { case none, pen, text, arrow }

    static let clickThreshold: CGFloat = 10
    static let minSelectionSize: CGFloat = 10
    static let penWidth: CGFloat = 4
    static let textFontSize: CGFloat = 18
    static let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .black]

    /// Final actions handled by the controller (copy / ocr / save).
    var onFinalAction: ((String) -> Void)?
    var onWindowClicked: ((WindowHitTestResult, Bool) -> Void)?
    var onCancel: (() -> Void)?

    let frozen: FrozenScreen
    private(set) var phase: Phase = .idle
    private(set) var tool: Tool = .none
    private(set) var selectionRect: NSRect?
    private var annotationColor: NSColor = CaptureSelectionView.palette[0]

    private var annotations: [CaptureAnnotation] = []
    private var currentStroke: PenStroke?
    private var currentArrow: ArrowAnnotation?

    // Selection-move state (drag the rect with no tool active).
    private var moveOrigin: NSPoint?
    private var preMoveRect: NSRect?
    private var preMoveAnnotations: [CaptureAnnotation] = []
    private var textEditor: AnnotationTextView?

    private var startPoint: NSPoint?
    private var endPoint: NSPoint?
    private var hoverHighlight: NSRect?
    private var trackingArea: NSTrackingArea?
    private var actionBar: NSView?
    private var undoButton: IconButton?
    private var toolButtons: [Tool: IconButton] = [:]
    private var colorButton: IconButton?
    private var colorDotLayers: [(NSButton, NSColor)] = [] // legacy, unused

    init(frame: NSRect, frozen: FrozenScreen) {
        self.frozen = frozen
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
        needsDisplay = true
    }

    // No dim overlay: the user prefers the frozen frame to look identical to
    // the live screen with zero dimming. Selection is communicated purely by
    // the hover/crosshair UI.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard phase == .idle else { return }
        let previous = hoverHighlight
        hoverHighlight = resolveWindowHighlight()
        if hoverHighlight != previous { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if phase == .pendingAction, let rect = selectionRect {
            commitTextEditor()
            if rect.contains(point) {
                switch tool {
                case .pen:
                    currentStroke = PenStroke(points: [clamped(point, in: rect)],
                                              color: annotationColor, width: Self.penWidth)
                    needsDisplay = true
                case .arrow:
                    currentArrow = ArrowAnnotation(start: clamped(point, in: rect),
                                                   end: clamped(point, in: rect),
                                                   color: annotationColor, width: Self.penWidth)
                    needsDisplay = true
                case .text:
                    beginTextEditor(at: point, in: rect)
                case .none:
                    // No tool active: drag repositions the selection
                    // (annotations travel with it).
                    moveOrigin = point
                    preMoveRect = rect
                    preMoveAnnotations = annotations
                }
                return
            }
            // Click outside the selection: discard annotations only if there
            // are none to lose, otherwise protect the work.
            guard annotations.isEmpty else { return }
            setTool(.none)
            dismissActionBar()
            selectionRect = nil
        }

        startPoint = point
        endPoint = point
        phase = .dragging
        selectionRect = nil
        hoverHighlight = resolveWindowHighlight()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Moving the whole selection.
        if let origin = moveOrigin, let original = preMoveRect, phase == .pendingAction {
            var newRect = original.offsetBy(dx: point.x - origin.x, dy: point.y - origin.y)
            if newRect.minX < bounds.minX { newRect.origin.x = bounds.minX }
            if newRect.minY < bounds.minY { newRect.origin.y = bounds.minY }
            if newRect.maxX > bounds.maxX { newRect.origin.x = bounds.maxX - newRect.width }
            if newRect.maxY > bounds.maxY { newRect.origin.y = bounds.maxY - newRect.height }
            let applied = NSPoint(x: newRect.minX - original.minX, y: newRect.minY - original.minY)
            annotations = Self.translated(preMoveAnnotations, by: applied)
            selectionRect = newRect
            moveActionBar(below: newRect)
            needsDisplay = true
            return
        }

        // Pen in progress.
        if var stroke = currentStroke, phase == .pendingAction, let rect = selectionRect {
            stroke.points.append(clamped(point, in: rect))
            currentStroke = stroke
            needsDisplay = true
            return
        }

        // Arrow in progress: drag updates the head position.
        if var arrow = currentArrow, phase == .pendingAction, let rect = selectionRect {
            arrow.end = clamped(point, in: rect)
            currentArrow = arrow
            needsDisplay = true
            return
        }

        guard phase == .dragging, let start = startPoint else { return }
        endPoint = point
        let dragged = max(abs(endPoint!.x - start.x), abs(endPoint!.y - start.y)) > Self.clickThreshold
        if dragged { hoverHighlight = nil }
        selectionRect = currentRect()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Finish selection move.
        if moveOrigin != nil {
            moveOrigin = nil
            preMoveRect = nil
            preMoveAnnotations = []
            return
        }

        // Finish pen stroke.
        if let stroke = currentStroke {
            annotations.append(.stroke(stroke))
            currentStroke = nil
            refreshUndoState()
            needsDisplay = true
            return
        }

        // Finish arrow.
        if let arrow = currentArrow {
            annotations.append(.arrow(arrow))
            currentArrow = nil
            refreshUndoState()
            needsDisplay = true
            return
        }

        guard phase == .dragging, let start = startPoint, let end = endPoint else { return }
        let dragged = max(abs(end.x - start.x), abs(end.y - start.y)) > Self.clickThreshold

        if !dragged {
            // Plain click: take the hovered window as-is (transparent corners).
            phase = .idle
            if let hit = WindowHitTester.hitTestAtMouse() {
                hoverHighlight = nil
                needsDisplay = true
                onWindowClicked?(hit, event.modifierFlags.contains(.shift))
                return
            }
            needsDisplay = true
            return
        }

        guard let rect = currentRect(), rect.width > Self.minSelectionSize, rect.height > Self.minSelectionSize else {
            phase = .idle
            selectionRect = nil
            needsDisplay = true
            return
        }
        phase = .pendingAction
        selectionRect = rect
        hoverHighlight = nil
        needsDisplay = true
        showActionBar(below: rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    // MARK: Tools

    func setTool(_ newTool: Tool) {
        commitTextEditor()
        tool = (tool == newTool) ? .none : newTool
        refreshToolUI()
    }

    func undoLastAnnotation() {
        if textEditor != nil {
            discardTextEditor()
            return
        }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        refreshUndoState()
        needsDisplay = true
    }

    // MARK: Text editor

    private func beginTextEditor(at point: NSPoint, in rect: NSRect) {
        discardTextEditor()
        let width = max(120, min(340, bounds.maxX - point.x - 8))
        let editor = AnnotationTextView(frame: NSRect(x: point.x, y: point.y - 28,
                                                      width: width, height: 28))
        editor.anchorTop = point
        editor.font = NSFont.systemFont(ofSize: Self.textFontSize, weight: .medium)
        editor.textColor = annotationColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = .zero
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.onCommit = { [weak self] in self?.commitTextEditor() }
        editor.onDiscard = { [weak self] in self?.discardTextEditor() }
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
    }

    /// Commit the live editor into a TextAnnotation (no-op if empty).
    func commitTextEditor() {
        guard let editor = textEditor else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        var usedHeight: CGFloat = 0
        if let layout = editor.layoutManager, let container = editor.textContainer {
            layout.ensureLayout(for: container)
            usedHeight = layout.usedRect(for: container).height
        }
        let origin = editor.anchorTop
        discardTextEditor()
        guard !text.isEmpty else { return }
        let annotation = TextAnnotation(point: NSPoint(x: origin.x, y: origin.y - usedHeight),
                                        text: editor.string.trimmingCharacters(in: .newlines),
                                        fontSize: Self.textFontSize, color: annotationColor)
        annotations.append(.text(annotation))
        refreshUndoState()
        needsDisplay = true
    }

    private func discardTextEditor() {
        guard let editor = textEditor else { return }
        editor.onCommit = nil
        editor.onDiscard = nil
        editor.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Composition

    /// Render selection + annotations at full backing-scale resolution.
    func composeFinalImage() -> CGImage? {
        commitTextEditor()
        guard let rect = selectionRect else { return nil }
        let scale = frozen.scale
        let w = Int((rect.width * scale).rounded())
        let h = Int((rect.height * scale).rounded())
        guard w >= 1, h >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: rect.width, height: rect.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.interpolationQuality = .high

        // Both the base pixels and the annotations live in the view's
        // bottom-left coordinate space; shift it so the selection's origin
        // lands at the bitmap origin, and clip away everything outside.
        cg.saveGState()
        cg.clip(to: NSRect(origin: .zero, size: rect.size))
        cg.translateBy(x: -rect.minX, y: -rect.minY)
        cg.draw(frozen.image, in: bounds)
        drawAnnotations()
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: Action bar

    private func showActionBar(below rect: NSRect) {
        dismissActionBar()
        let bar = buildActionBar()
        addSubview(bar)
        let size = bar.frame.size
        var x = rect.maxX - size.width
        x = max(8, min(x, bounds.maxX - size.width - 8))
        var y = rect.minY - size.height - 10
        if y < bounds.minY + 4 { y = min(rect.maxY + 10, bounds.maxY - size.height - 4) }
        bar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        actionBar = bar
        refreshToolUI()
    }

    func dismissActionBar() {
        actionBar?.removeFromSuperview()
        actionBar = nil
        toolButtons.removeAll()
        undoButton = nil
        colorButton = nil
    }

    /// Repositions the existing action bar while the selection is dragged
    /// (same placement rules as showActionBar, without rebuilding it).
    private func moveActionBar(below rect: NSRect) {
        guard let bar = actionBar else { return }
        let size = bar.frame.size
        var x = rect.maxX - size.width
        x = max(8, min(x, bounds.maxX - size.width - 8))
        var y = rect.minY - size.height - 10
        if y < bounds.minY + 4 { y = min(rect.maxY + 10, bounds.maxY - size.height - 4) }
        bar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    /// SF Symbol letters localize (textformat.abc renders 甲乙丙 on Chinese
    /// systems), so the "T" text tool draws its own glyph instead.
    private static func makeLetterIconButton(_ letter: String, _ name: String,
                                             _ handler: @escaping () -> Void) -> IconButton {
        let button = IconButton(frame: .zero)
        let image = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2,
                                  y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = true // tints with contentTintColor like SF Symbols
        button.image = image
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.contentTintColor = .labelColor
        let trampoline = ClosureTarget(handler: handler)
        objc_setAssociatedObject(button, "action.trampoline", trampoline, .OBJC_ASSOCIATION_RETAIN)
        button.target = trampoline
        button.action = #selector(ClosureTarget.fire)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }

    private static func makeIconButton(_ symbol: String, _ name: String,
                                       tint: NSColor = .labelColor,
                                       _ handler: @escaping () -> Void) -> IconButton {
        let button = IconButton(frame: .zero)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.contentTintColor = tint
        let trampoline = ClosureTarget(handler: handler)
        objc_setAssociatedObject(button, "action.trampoline", trampoline, .OBJC_ASSOCIATION_RETAIN)
        button.target = trampoline
        button.action = #selector(ClosureTarget.fire)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }

    private func buildActionBar() -> NSView {
        let stack = NSStackView(views: [])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

        // Tools
        let pen = Self.makeIconButton("scribble.variable", "画笔") { [weak self] in self?.setTool(.pen) }
        let arrow = Self.makeIconButton("arrow.up.right", "箭头") { [weak self] in self?.setTool(.arrow) }
        let text = Self.makeLetterIconButton("T", "文字") { [weak self] in self?.setTool(.text) }
        let undo = Self.makeIconButton("arrow.uturn.backward", "撤销") { [weak self] in self?.undoLastAnnotation() }
        undo.isEnabled = false
        toolButtons = [.pen: pen, .arrow: arrow, .text: text]
        undoButton = undo
        stack.addArrangedSubview(pen)
        stack.addArrangedSubview(arrow)
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(undo)

        let toolsSeparator = makeSeparator()
        stack.addArrangedSubview(toolsSeparator)

        // Color picker: one button; clicking pops a swatch menu.
        let colorPick = IconButton(frame: .zero)
        colorPick.isBordered = false
        colorPick.toolTip = "标注颜色"
        colorPick.setAccessibilityLabel("标注颜色")
        colorButton = colorPick
        updateColorButton()
        let colorTrampoline = ClosureTarget(handler: { [weak self, weak colorPick] in
            guard let self, let button = colorPick else { return }
            self.showColorMenu(from: button)
        })
        objc_setAssociatedObject(colorPick, "action.trampoline", colorTrampoline, .OBJC_ASSOCIATION_RETAIN)
        colorPick.target = colorTrampoline
        colorPick.action = #selector(ClosureTarget.fire)
        NSLayoutConstraint.activate([
            colorPick.widthAnchor.constraint(equalToConstant: 28),
            colorPick.heightAnchor.constraint(equalToConstant: 28),
        ])
        stack.addArrangedSubview(colorPick)

        let actionsSeparator = makeSeparator()
        stack.addArrangedSubview(actionsSeparator)
        stack.setCustomSpacing(7, after: toolsSeparator)
        stack.setCustomSpacing(7, after: actionsSeparator)

        // Cancel + final actions (order: 复制 last, 保存 second-to-last)
        stack.addArrangedSubview(Self.makeIconButton("xmark", "取消", tint: .systemRed) { [weak self] in
            self?.onCancel?()
        })
        for (symbol, name, action) in [("doc.text.viewfinder", "OCR 文字识别", "ocr"),
                                       ("square.and.arrow.down", "保存", "save"),
                                       ("doc.on.doc", "复制", "copy")] {
            stack.addArrangedSubview(Self.makeIconButton(symbol, name) { [weak self] in
                self?.onFinalAction?(action)
            })
        }

        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        stack.layer?.cornerRadius = 8
        // Depth: soft drop shadow below the bar plus a hairline top highlight,
        // so the floating bar reads as raised off the screenshot.
        stack.layer?.shadowColor = NSColor.black.cgColor
        stack.layer?.shadowOpacity = 0.35
        stack.layer?.shadowRadius = 9
        stack.layer?.shadowOffset = NSSize(width: 0, height: -3)
        stack.layer?.borderWidth = 0.5
        stack.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        stack.setFrameSize(size)
        return stack
    }

    private func makeSeparator() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 18))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    private func refreshToolUI() {
        for (toolKind, button) in toolButtons {
            button.isSelectedStyle = (tool == toolKind)
        }
        updateColorButton()
        refreshUndoState()
    }

    private func refreshUndoState() {
        let hasContent = !annotations.isEmpty || textEditor != nil
        undoButton?.isEnabled = hasContent
        undoButton?.contentTintColor = hasContent ? .labelColor : .secondaryLabelColor
        undoButton?.layer?.opacity = hasContent ? 1 : 0.75
    }

    // MARK: Color picker

    private static let paletteNames = ["红色", "黄色", "绿色", "蓝色", "黑色"]

    private func updateColorButton() {
        colorButton?.image = Self.swatchImage(annotationColor, size: 15, ring: true)
    }

    private func showColorMenu(from button: NSView) {
        let menu = NSMenu()
        for (index, color) in Self.palette.enumerated() {
            let item = NSMenuItem(title: Self.paletteNames[index],
                                  action: #selector(ClosureTarget.fire),
                                  keyEquivalent: "")
            item.image = Self.swatchImage(color)
            item.state = (color == annotationColor) ? .on : .off
            let target = ClosureTarget(handler: { [weak self] in
                self?.annotationColor = color
                self?.updateColorButton()
            })
            objc_setAssociatedObject(item, "action.trampoline", target, .OBJC_ASSOCIATION_RETAIN)
            item.target = target
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: -6), in: button)
    }

    private static func swatchImage(_ color: NSColor, size: CGFloat = 14, ring: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset: CGFloat = ring ? 1.5 : 1
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            color.setFill()
            path.fill()
            if ring {
                NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Drawing

    // MARK: Dim fade-in

    /// 0 = identical to the live screen, 1 = fully dimmed (20% black).
    private var dimProgress: CGFloat = 0
    private var dimTimer: Timer?
    private var dimStart: CFTimeInterval?

    /// Called right after the panel becomes visible. The first frame renders
    /// with dimProgress 0 (pixel-identical to the live screen), then the dim
    /// fades in over 200 ms with an ease-out curve at 120 Hz.
    func startDimFade() {
        dimTimer?.invalidate()
        dimProgress = 0
        dimStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepDimFade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer
    }

    private func stepDimFade() {
        guard let start = dimStart else { return }
        let t = min(1, (CACurrentMediaTime() - start) / 0.2)
        dimProgress = 1 - pow(1 - t, 3) // ease-out cubic
        needsDisplay = true
        if t >= 1 {
            dimTimer?.invalidate()
            dimTimer = nil
        }
    }

    func stopDimFade() {
        dimTimer?.invalidate()
        dimTimer = nil
        dimProgress = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.interpolationQuality = .high
        context.draw(frozen.image, in: bounds)

        // Dim the whole screen; the hole below re-draws the untouched frame
        // for the region being picked, so it stays bright. dimProgress fades
        // 0→1 after the session starts (first frame stays pixel-identical to
        // the live screen), so the arrival reads as smooth, not a flash.
        NSColor.black.withAlphaComponent(0.2 * dimProgress).setFill()
        bounds.fill()

        // The "hole": the region being picked (or the hovered window) shows the
        // untouched still frame, exactly like the real screen.
        let hole: NSRect
        switch phase {
        case .pendingAction:
            hole = selectionRect ?? .zero
        case .dragging:
            hole = currentRect() ?? .zero
        case .idle:
            hole = hoverHighlight ?? .zero
        }
        guard !hole.isEmpty else { return }

        context.saveGState()
        context.clip(to: hole)
        context.draw(frozen.image, in: bounds)
        context.restoreGState()

        let path = NSBezierPath(rect: hole)
        path.lineWidth = 2
        NSColor.systemBlue.setStroke()
        path.stroke()

        // Annotations (also draw the in-progress stroke live).
        context.saveGState()
        context.clip(to: hole)
        drawAnnotations()
        if let stroke = currentStroke { drawStroke(stroke) }
        if let arrow = currentArrow { drawArrow(arrow) }
        context.restoreGState()
    }

    private func drawAnnotations() {
        for annotation in annotations {
            switch annotation {
            case .stroke(let stroke): drawStroke(stroke)
            case .text(let text): drawText(text)
            case .arrow(let arrow): drawArrow(arrow)
            }
        }
    }

    /// Shifts every annotation by `d` while the selection is being dragged.
    private static func translated(_ annotations: [CaptureAnnotation], by d: NSPoint) -> [CaptureAnnotation] {
        annotations.map { annotation in
            switch annotation {
            case .stroke(var stroke):
                stroke.points = stroke.points.map { NSPoint(x: $0.x + d.x, y: $0.y + d.y) }
                return .stroke(stroke)
            case .text(var text):
                text.point = NSPoint(x: text.point.x + d.x, y: text.point.y + d.y)
                return .text(text)
            case .arrow(var arrow):
                arrow.start = NSPoint(x: arrow.start.x + d.x, y: arrow.start.y + d.y)
                arrow.end = NSPoint(x: arrow.end.x + d.x, y: arrow.end.y + d.y)
                return .arrow(arrow)
            }
        }
    }

    private func drawArrow(_ arrow: ArrowAnnotation) {
        let dx = arrow.end.x - arrow.start.x
        let dy = arrow.end.y - arrow.start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let unit = NSPoint(x: dx / length, y: dy / length)
        let headLength = max(11, arrow.width * 3.2)
        let headSpread = CGFloat.pi / 7 // half-angle of the head, ~26°

        // Shaft: from tail to just behind the head.
        let shaftEnd = NSPoint(x: arrow.end.x - unit.x * headLength * 0.55,
                               y: arrow.end.y - unit.y * headLength * 0.55)
        let shaft = NSBezierPath()
        shaft.lineWidth = arrow.width
        shaft.lineCapStyle = .round
        shaft.move(to: arrow.start)
        shaft.line(to: shaftEnd)
        arrow.color.setStroke()
        shaft.stroke()

        // Head: solid triangle at the tip.
        let head = NSBezierPath()
        head.move(to: arrow.end)
        head.line(to: NSPoint(x: arrow.end.x - headLength * cos(atan2(dy, dx) - headSpread),
                              y: arrow.end.y - headLength * sin(atan2(dy, dx) - headSpread)))
        head.line(to: NSPoint(x: arrow.end.x - headLength * cos(atan2(dy, dx) + headSpread),
                              y: arrow.end.y - headLength * sin(atan2(dy, dx) + headSpread)))
        head.close()
        arrow.color.setFill()
        head.fill()
    }

    private func drawStroke(_ stroke: PenStroke) {
        guard !stroke.points.isEmpty else { return }
        let path = NSBezierPath()
        path.lineWidth = stroke.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if stroke.points.count == 1 {
            let r = stroke.width / 2
            let p = stroke.points[0]
            path.append(NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r,
                                                    width: stroke.width, height: stroke.width)))
        } else {
            // Midpoint smoothing: keeps strokes visually soft without curves.
            path.move(to: stroke.points[0])
            for i in 1..<stroke.points.count {
                let prev = stroke.points[i - 1], cur = stroke.points[i]
                let mid = NSPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
                path.line(to: mid)
            }
            path.line(to: stroke.points[stroke.points.count - 1])
        }
        stroke.color.setStroke()
        path.stroke()
    }

    private func drawText(_ annotation: TextAnnotation) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .medium),
            .foregroundColor: annotation.color
        ]
        NSAttributedString(string: annotation.text, attributes: attributes)
            .draw(at: annotation.point)
    }

    // MARK: Private

    private func clamped(_ point: NSPoint, in rect: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func currentRect() -> NSRect? {
        guard let start = startPoint, let end = endPoint else { return nil }
        let raw = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        return raw.intersection(bounds)
    }

    private func resolveWindowHighlight() -> NSRect? {
        guard let window = self.window, let hit = WindowHitTester.hitTestAtMouse() else { return nil }
        return convert(window.convertFromScreen(hit.bounds), from: nil)
    }
}

// MARK: - Controller

@MainActor
final class CaptureController: NSObject {
    private var panels: [CapturePanel] = []
    private var views: [CaptureSelectionView] = []
    private var pendingRegion: (view: CaptureSelectionView, rect: NSRect)?
    private var keyRetryWork: DispatchWorkItem?

    /// Panels persist across sessions, ordered front but fully transparent
    /// (alpha 0) and mouse-transparent while idle. macOS 26 plays a zoom
    /// animation whenever a NEW window is ordered front — a fullscreen overlay
    /// opening reads as the whole screen zooming in. Reusing always-ordered
    /// panels means pressing F1 never triggers a window "open" event at all.
    private var panelPool: [(panel: CapturePanel, frame: NSRect)] = []

    override init() {
        super.init()
        warmOverlayPool()
    }

    /// Build the overlay windows up front, invisible, so F1 only flips
    /// visibility in place.
    private func warmOverlayPool() {
        for screen in NSScreen.screens {
            guard !panelPool.contains(where: { $0.frame == screen.frame }) else { continue }
            let panel = CapturePanel(contentRect: screen.frame)
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            panelPool.append((panel, screen.frame))
        }
    }

    var isRunning: Bool { !panels.isEmpty }

    func start() {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            Toast.show("截图需要「屏幕录制」权限，请在弹窗中允许")
            return
        }
        Task { await runSession() }
    }

    private func runSession() async {
        let screens: [FrozenScreen]
        do {
            screens = try await FrozenCapture.captureAllScreens()
        } catch {
            Toast.show("截图失败：无法捕获屏幕（权限或显示状态变化）")
            return
        }
        guard !screens.isEmpty else { return }

        for screen in screens {
            let view = CaptureSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), frozen: screen)
            view.onWindowClicked = { [weak self] hit, shift in self?.windowClicked(hit: hit, ocr: shift) }
            view.onFinalAction = { [weak self] action in self?.finalAction(action, from: view) }
            view.onCancel = { [weak self] in self?.teardown() }
            let panel: CapturePanel
            if let idx = panelPool.firstIndex(where: { $0.frame == screen.frame }) {
                panel = panelPool[idx].panel
            } else {
                // Screen topology changed since launch: create the panel
                // hidden so its first fronting is never seen.
                panel = CapturePanel(contentRect: screen.frame)
                panel.setFrame(screen.frame, display: false)
                panel.alphaValue = 0
                panel.ignoresMouseEvents = true
                panel.orderFrontRegardless()
                panelPool.append((panel, screen.frame))
            }
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }

        // Flip visibility in place — no window open event, no animation.
        for panel in panels {
            panel.ignoresMouseEvents = false
            panel.alphaValue = 1
        }
        for view in views { view.startDimFade() }
        // Anchor keyboard focus on the panel under the mouse (Esc needs the
        // responder chain).
        let mouse = NSEvent.mouseLocation
        let anchor = panels.first { $0.frame.contains(mouse) } ?? panels.first
        anchor?.makeKeyAndOrderFront(nil)
        if let view = anchor?.contentView { anchor?.makeFirstResponder(view) }
        armKeyWindowWatchdog(for: anchor)
    }

    /// The hotkey can fire while a status-menu tracking loop still owns focus,
    /// in which case makeKeyAndOrderFront silently fails and Esc dies. Keep
    /// re-asserting key focus; give up (and tear down) if it never takes.
    private func armKeyWindowWatchdog(for panel: CapturePanel?, attempts: Int = 12) {
        keyRetryWork?.cancel()
        guard attempts > 0 else {
            teardown()
            Toast.show("截图已取消，请稍后重试")
            return
        }
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.panels.contains(where: { $0 === panel }) else { return }
            if panel.isKeyWindow { return }
            panel.makeKeyAndOrderFront(nil)
            if let view = panel.contentView { panel.makeFirstResponder(view) }
            self.armKeyWindowWatchdog(for: panel, attempts: attempts - 1)
        }
        keyRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Decisions

    private func finalAction(_ action: String, from view: CaptureSelectionView) {
        let anchorFrame = view.window?.frame ?? .zero
        let image = view.composeFinalImage()
        teardown()
        guard let image else {
            Toast.show("截图失败")
            return
        }
        switch action {
        case "copy":
            Self.copyImage(image)
        case "ocr":
            Task { @MainActor in
                let text = await Self.recognizeText(in: image)
                guard !text.isEmpty else {
                    Toast.show("未识别到文字")
                    return
                }
                OCRResultWindowController.shared.show(text: text, near: anchorFrame)
            }
        case "save":
            let name = "截图 \(Self.dateFormatter.string(from: Date())).png"
            ImageSaveSupport.saveWithPanel(image, defaultName: name)
        default:
            break
        }
    }

    private func windowClicked(hit: WindowHitTestResult, ocr: Bool) {
        let windowID = hit.windowID
        let ownerPID = hit.ownerPID
        let anchorFrame = hit.bounds
        teardown()
        Task { @MainActor in
            do {
                let image = try await FrozenCapture.captureWindow(windowID: windowID, ownerPID: ownerPID)
                if ocr {
                    let text = await Self.recognizeText(in: image)
                    guard !text.isEmpty else {
                        Toast.show("未识别到文字")
                        return
                    }
                    OCRResultWindowController.shared.show(text: text, near: anchorFrame)
                } else {
                    Self.copyImage(image)
                }
            } catch {
                Toast.show("窗口截图失败")
            }
        }
    }

    func cancel() { teardown() }

    private func teardown() {
        keyRetryWork?.cancel()
        keyRetryWork = nil
        pendingRegion = nil
        for view in views {
            view.onFinalAction = nil
            view.onWindowClicked = nil
            view.onCancel = nil
            view.stopDimFade()
            view.dismissActionBar()
        }
        for panel in panels {
            panel.delegate = nil
            // Hide in place: keep the window ordered front but transparent and
            // mouse-transparent. Never orderOut — re-fronting a window plays
            // Tahoe's zoom animation again.
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
        }
        panels.removeAll()
        views.removeAll()
    }

    // MARK: Outputs

    private static func copyImage(_ image: CGImage) {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        Toast.show("已复制到剪贴板")
    }

    /// Vision OCR (Chinese + English), background queue, main-thread result.
    private static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                var langs = ["zh-Hans", "zh-Hant", "en-US"]
                if let supported = try? request.supportedRecognitionLanguages() {
                    let filtered = langs.filter { supported.contains($0) }
                    langs = filtered.isEmpty ? Array(supported.prefix(2)) : filtered
                }
                request.recognitionLanguages = langs
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                do {
                    try handler.perform([request])
                    let text = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: text)
                } catch {
                    NSLog("Waycast OCR failed: \(error)")
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

// MARK: - OCR result window

/// Floating window showing recognized text in an editable, selectable box.
@MainActor
final class OCRResultWindowController: NSObject {
    static let shared = OCRResultWindowController()

    private var window: NSWindow?
    private var textView: NSTextView?

    func show(text: String, near screenFrame: NSRect) {
        close()

        let contentSize = NSSize(width: 460, height: 380)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "OCR 识别结果"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 320, height: 220)

        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))

        // Editable text area.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 34,
                                                width: contentSize.width,
                                                height: contentSize.height - 34))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.font = NSFont.systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.drawsBackground = true
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        scroll.documentView = editor
        content.addSubview(scroll)

        // Bottom bar: copy everything / char count.
        let copyButton = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.frame = NSRect(x: 12, y: 5, width: 84, height: 24)
        copyButton.autoresizingMask = [.maxXMargin]
        content.addSubview(copyButton)

        let countLabel = NSTextField(labelWithString: "\(text.count) 字符")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: contentSize.width - countLabel.frame.width - 14, y: 10)
        countLabel.autoresizingMask = [.minXMargin]
        content.addSubview(countLabel)

        win.contentView = content

        // Place over the captured area (clamped to the nearest screen).
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: screenFrame.midX, y: screenFrame.midY)) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: (screenFrame.isEmpty ? visible.midX : screenFrame.midX) - contentSize.width / 2,
                             y: (screenFrame.isEmpty ? visible.midY : screenFrame.midY) - contentSize.height / 2)
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - contentSize.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - contentSize.height - 8))
        win.setFrameOrigin(origin)

        window = win
        textView = editor
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        textView = nil
    }

    @objc private func copyAll() {
        guard let text = textView?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("已复制到剪贴板")
    }
}

// MARK: - Save support

@MainActor
enum ImageSaveSupport {
    static func saveWithPanel(_ image: CGImage, defaultName: String) {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
