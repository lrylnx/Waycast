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
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        } else if hovering && isEnabled {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
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

struct RoundedRectAnnotation {
    var rect: NSRect
    var color: NSColor
    var width: CGFloat
}

enum CaptureAnnotation {
    case stroke(PenStroke)
    case text(TextAnnotation)
    case arrow(ArrowAnnotation)
    case roundedRect(RoundedRectAnnotation)
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

// MARK: - Empty shell overlay (instant acknowledgement)

/// 空壳覆盖层视图：**什么都不画**。
///
/// 为什么要它：抓帧要 30ms 左右（实测），这段时间里如果屏幕一点变化都没有，
/// 手感就是"按了没反应"。于是按键瞬间先把这个空壳挂上去 —— 屏幕像素与实时
/// 完全一致（什么都不画），所以**随后那次抓屏不会把覆盖层录进去**，但它让面板
/// 变成"可见且可交互"，十字光标立刻生效。用户 0ms 就得到确认，30ms 后真正的
/// 冻结帧 + 遮罩再无缝接上（两者像素本来就一样，看不出切换）。
final class CaptureShellView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // 故意什么都不画：保持屏幕像素与实时一致。
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }
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
    enum Tool { case none, pen, text, arrow, roundedRect }

    static let clickThreshold: CGFloat = 10
    static let minSelectionSize: CGFloat = 10
    static let handleTolerance: CGFloat = 6
    static let penWidth: CGFloat = 4
    static let textFontSize: CGFloat = 18
    static let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .black]

    /// Final actions handled by the controller (copy / ocr / save).
    var onFinalAction: ((String) -> Void)?
    var onWindowClicked: ((WindowHitTestResult, Bool) -> Void)?
    var onCancel: (() -> Void)?

    let frozen: FrozenScreen
    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            // 光标矩形随阶段切换：空闲/拖拽是十字，编辑态交给 applyCursor。
            window?.invalidateCursorRects(for: self)
        }
    }
    private(set) var tool: Tool = .none
    private(set) var selectionRect: NSRect?
    private var annotationColor: NSColor = CaptureSelectionView.palette[0]

    private var annotations: [CaptureAnnotation] = []
    private var currentStroke: PenStroke?
    private var currentArrow: ArrowAnnotation?
    private var currentRoundedRect: RoundedRectAnnotation?
    private var roundedRectStart: NSPoint?

    // Selection-move state (drag the rect with no tool active).
    private var moveOrigin: NSPoint?
    private var preMoveRect: NSRect?
    private var preMoveAnnotations: [CaptureAnnotation] = []
    private var textEditor: AnnotationTextView?

    // Selection-resize state (drag a corner/edge of the rect).
    private struct ResizeEdges: OptionSet {
        let rawValue: UInt8
        static let minX = ResizeEdges(rawValue: 1 << 0)
        static let maxX = ResizeEdges(rawValue: 1 << 1)
        static let minY = ResizeEdges(rawValue: 1 << 2)
        static let maxY = ResizeEdges(rawValue: 1 << 3)
    }
    private var resizeState: (edges: ResizeEdges, original: NSRect)?

    private var startPoint: NSPoint?
    private var endPoint: NSPoint?
    private var hoverHighlight: NSRect?
    private var trackingArea: NSTrackingArea?
    private var actionBar: NSView?
    private var undoButton: IconButton?
    private var toolButtons: [Tool: IconButton] = [:]
    private var colorButton: IconButton?
    private var colorDotLayers: [(NSButton, NSColor)] = [] // legacy, unused

    // —— 标注的悬停 / 拖动 / 滚轮缩放（选择模式下，tool == .none）——
    /// 悬停命中的标注：画虚线提示框 + 手型光标，告诉用户"这坨可以拖"。
    private var hoveredAnnotationIndex: Int?
    /// 正在拖动的标注：数组下标 + 拖动前的原样 + 按下点。
    /// 存「原样 + 位移」而不是就地累加，是为了拖动过程零漂移（每次都从原件算）。
    private var draggingAnnotation: (index: Int, original: CaptureAnnotation, start: NSPoint)?

    // —— 工具的默认粗细 / 字号（选中工具后滚轮可调）——
    /// 原来这三处都直接用 static 常量，滚轮一来就得变成实例值；
    /// static 值保留作默认。
    private var activePenWidth: CGFloat = CaptureSelectionView.penWidth
    private var activeFontSize: CGFloat = CaptureSelectionView.textFontSize
    /// 滚轮调节时在选区顶部短暂显示的提示（"画笔 6pt"），1.2s 后自动消失。
    private var sizeHint: String?
    private var sizeHintWork: DispatchWorkItem?

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

    // 选区之外的区域由 draw(_:) 里的黑色遮罩压暗（强度见下方 dimStrength）。

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

    /// 十字光标覆盖整屏：这是**零成本**的「已经进入截图态」信号，遮罩还没浮上来
    /// 时用户也能立刻确认按键生效了。编辑态（已框选、可拖手柄）不铺光标矩形，
    /// 让 `applyCursor` 按手柄方向设箭头/双向箭头。
    override func resetCursorRects() {
        super.resetCursorRects()
        if phase != .pendingAction {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        // ⌘Z 撤销上一个标注（箭头 / 笔画 / 文字 / 矩形）。
        // 两条路都接上：主菜单「撤销」的 key equivalent 也会派发到 `undo(_:)`，
        // 但截图覆盖层是 nonactivatingPanel、应用多半没被激活，菜单快捷键不一定
        // 有机会执行 —— 所以这里直接判键，不依赖菜单。
        if Self.isUndoKeystroke(event) {
            undo(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// 严格只认 ⌘Z：⇧⌘Z 是「重做」，不该走到撤销上。
    /// （capsLock / fn / 小键盘这些无关位不算，见 deviceIndependentFlagsMask 的取法。）
    private static func isUndoKeystroke(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        let significant = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return significant == .command
    }

    /// 主菜单「撤销」的 action（target = nil，沿响应链找到这里）。
    /// 返回给菜单用，同时也让 `keyDown` 那条路有个统一入口。
    @objc func undo(_ sender: Any?) {
        // 正在输入文字时，⌘Z 该撤的是刚打的字，而不是删掉上一个标注。
        if let editor = textEditor, editor.window?.firstResponder === editor {
            editor.undoManager?.undo()
            return
        }
        undoLastAnnotation()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Cursor feedback over the selection border in editing mode.
        if phase == .pendingAction, tool == .none, let rect = selectionRect {
            // 手柄优先：在边缘/角上仍然用方向光标，且不显示标注提示框。
            if let edges = resizeEdges(at: point, in: rect) {
                if hoveredAnnotationIndex != nil { hoveredAnnotationIndex = nil; needsDisplay = true }
                applyCursor(for: edges)
                return
            }
            // 悬停在标注上 → 高亮 + 手型光标，示意「可拖动 / 可滚轮缩放」。
            let idx = annotationIndex(at: point)
            if idx != hoveredAnnotationIndex {
                hoveredAnnotationIndex = idx
                needsDisplay = true
            }
            (idx != nil ? NSCursor.openHand : NSCursor.arrow).set()
            return
        }
        guard phase == .idle else { return }
        let previous = hoverHighlight
        hoverHighlight = resolveWindowHighlight()
        if hoverHighlight != previous { needsDisplay = true }
    }

    /// 滚轮：选中工具时调当前工具的粗细/字号；选择模式（无工具）下缩放
    /// 鼠标下的那个标注 —— 画完之后嫌小/嫌大，滚一下就行，不用重画。
    override func scrollWheel(with event: NSEvent) {
        guard phase == .pendingAction else { return }
        // 触控板的惯性阶段不响应：否则轻扫一下标注会自己缩个不停。
        guard event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let magnitude = CGFloat(min(abs(delta), 3))
        let factor: CGFloat = delta > 0 ? 1 + 0.07 * magnitude : 1 - 0.07 * magnitude

        if tool != .none {
            adjustActiveToolSize(by: factor)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = annotationIndex(at: point) else { return }
        annotations[idx] = Self.scaled(annotations[idx], by: factor)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if phase == .pendingAction, let rect = selectionRect {
            commitTextEditor()
            // Grab a resize handle first: corners/edges win over "inside → move"
            // and "outside → new selection", so the border is always resizable.
            if tool == .none, let edges = resizeEdges(at: point, in: rect) {
                resizeState = (edges, rect)
                applyCursor(for: edges)
                return
            }
            if rect.contains(point) {
                switch tool {
                case .pen:
                    currentStroke = PenStroke(points: [clamped(point, in: rect)],
                                              color: annotationColor, width: activePenWidth)
                    needsDisplay = true
                case .arrow:
                    currentArrow = ArrowAnnotation(start: clamped(point, in: rect),
                                                   end: clamped(point, in: rect),
                                                   color: annotationColor, width: activePenWidth)
                    needsDisplay = true
                case .roundedRect:
                    let p = clamped(point, in: rect)
                    roundedRectStart = p
                    currentRoundedRect = RoundedRectAnnotation(rect: NSRect(origin: p, size: .zero),
                                                               color: annotationColor,
                                                               width: activePenWidth)
                    needsDisplay = true
                case .text:
                    beginTextEditor(at: point, in: rect)
                case .none:
                    // No tool active. Grab an existing annotation first — pressing
                    // one lets you DRAG it to a better spot (the whole point of
                    // this mode besides moving/resizing the selection itself).
                    if let idx = annotationIndex(at: point) {
                        draggingAnnotation = (idx, annotations[idx], point)
                        NSCursor.closedHand.set()
                    } else {
                        // Otherwise drag repositions the selection (annotations
                        // travel with it).
                        moveOrigin = point
                        preMoveRect = rect
                        preMoveAnnotations = annotations
                    }
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

        // Resizing via a grabbed corner/edge.
        if let state = resizeState, phase == .pendingAction {
            let newRect = resizedRect(state.original, edges: state.edges, to: point)
            selectionRect = newRect
            moveActionBar(below: newRect)
            needsDisplay = true
            return
        }

        // Dragging a single annotation to a better spot.
        if let drag = draggingAnnotation, phase == .pendingAction {
            let d = NSPoint(x: point.x - drag.start.x, y: point.y - drag.start.y)
            annotations[drag.index] = Self.translated([drag.original], by: d)[0]
            needsDisplay = true
            return
        }

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

        // Rounded rect in progress: drag defines the box.
        if currentRoundedRect != nil, phase == .pendingAction,
           let rect = selectionRect, let start = roundedRectStart {
            let p = clamped(point, in: rect)
            currentRoundedRect?.rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                              width: abs(p.x - start.x), height: abs(p.y - start.y))
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
        // Finish dragging a single annotation.
        if draggingAnnotation != nil {
            draggingAnnotation = nil
            hoveredAnnotationIndex = nil   // 交给 mouseMoved 重算
            NSCursor.arrow.set()
            needsDisplay = true
            return
        }

        // Finish a resize drag.
        if resizeState != nil {
            resizeState = nil
            if let rect = selectionRect { moveActionBar(below: rect) }
            NSCursor.arrow.set()
            needsDisplay = true
            return
        }

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

        // Finish rounded rect (ignore zero-size click without drag).
        if let rr = currentRoundedRect {
            currentRoundedRect = nil
            roundedRectStart = nil
            if rr.rect.width > 2, rr.rect.height > 2 {
                annotations.append(.roundedRect(rr))
                refreshUndoState()
            }
            needsDisplay = true
            return
        }

        guard phase == .dragging, let start = startPoint, let end = endPoint else { return }
        let dragged = max(abs(end.x - start.x), abs(end.y - start.y)) > Self.clickThreshold

        if !dragged {
            // Plain click: take the hovered window — but instead of shipping
            // it straight to the clipboard, select its region so the user can
            // annotate / reposition / choose 复制·保存·OCR like a drag pick.
            phase = .idle
            if let hit = WindowHitTester.hitTestAtMouse() {
                hoverHighlight = nil
                // Shift+click keeps the shortcut: capture the window and run
                // OCR immediately.
                if event.modifierFlags.contains(.shift) {
                    needsDisplay = true
                    onWindowClicked?(hit, true)
                    return
                }
                if let screenWindow = window {
                    let local = convert(screenWindow.convertFromScreen(hit.bounds), from: nil)
                    let rect = local.intersection(bounds)
                    if rect.width > Self.minSelectionSize, rect.height > Self.minSelectionSize {
                        selectionRect = rect
                        phase = .pendingAction
                        needsDisplay = true
                        showActionBar(below: rect)
                        return
                    }
                }
                // Window lives on another display (no local geometry here):
                // fall back to direct window capture → clipboard.
                needsDisplay = true
                onWindowClicked?(hit, false)
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
        editor.font = NSFont.systemFont(ofSize: activeFontSize, weight: .medium)
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
        // 编辑期间滚轮可能改了 activeFontSize —— 落盘要用**编辑器自己的**字号，
        // 不然显示和保存会不一致。
        let fontSize = editor.font?.pointSize ?? activeFontSize
        discardTextEditor()
        guard !text.isEmpty else { return }
        let annotation = TextAnnotation(point: NSPoint(x: origin.x, y: origin.y - usedHeight),
                                        text: editor.string.trimmingCharacters(in: .newlines),
                                        fontSize: fontSize, color: annotationColor)
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
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // MUST be set BEFORE creating the graphics context: the context bakes
        // its point→pixel scale from the rep's size at creation time. Setting
        // it afterwards leaves the context in raw pixel units, so the base
        // frame was composited at half scale into the bitmap's lower-left
        // corner (everything else transparent/black).
        rep.size = NSSize(width: rect.width, height: rect.height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

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

    /// OCR 按钮的图标：圆角框里写「OCR」三个字。
    ///
    /// 为什么不用 SF Symbol：`doc.text.viewfinder` 只是个「取景框 + 文本」的抽象图形，
    /// 一眼看不出是文字识别；工具栏上直接写 OCR 最直白。这和「T」（文字工具）按钮是
    /// 同一套做法 —— 那个也得自绘，因为 SF Symbol 的 `textformat.abc` 在中文系统上
    /// 会渲染成「甲乙丙」。
    ///
    /// 尺寸按**实际字体度量**定，不是拍脑袋：
    ///
    /// - 三字母的难点在宽度。想让框窄下来又不把字压成糊，用系统字体的 **condensed
    ///   宽度特性**（`withSymbolicTraits(.condensed)`）：字形不变形、字高不缩水，
    ///   只横向收窄 —— 7pt Bold 的 `"OCR"` 从 15.04pt 收到 12.53pt（−17%）。
    ///   再用 kern −0.9 收到 **11.03pt**（`NSAttributedString.size()` 量的）。
    /// - 框 **14×13**、描边 1pt → 内空 12pt，左右各留 ~0.5pt 边距。
    /// - 14pt 的墨迹宽度和工具栏邻居（实测 9–13pt：画笔 12 / 箭头 9 / 撤销 13 /
    ///   复制 13）是同一量级；旧版 22.6pt 明显比别人胖一圈（用户实测反馈）。
    /// - 高度 13 落在邻居的 9–16pt 中间，不会显得突兀。
    ///
    /// `draw(at:)` 的行盒中心恰好等于字冠中心（SF 字体 ascender ≈ capHeight +
    /// |descender|），所以按行盒居中就是视觉居中。
    ///
    /// `height` 是给不同工具条用的：截图工具栏（28pt 按钮）用 13，贴图的小工具条
    /// （24pt 按钮）也用 13 —— 和旁边 12pt 的 SF Symbol 视觉重量对齐。
    static func ocrGlyphIcon(height: CGFloat = 13) -> NSImage {
        let design = NSSize(width: 14, height: 13)      // 设计稿尺寸，按 height 等比缩放
        let k = height / design.height
        let canvas = NSSize(width: design.width * k, height: height)
        let image = NSImage(size: canvas, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current else { return false }
            ctx.saveGraphicsState()
            let t = NSAffineTransform()
            t.scale(by: k)
            t.concat()

            let stroke: CGFloat = 1.0
            let box = NSRect(origin: .zero, size: design).insetBy(dx: stroke / 2, dy: stroke / 2)
            let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
            path.lineWidth = stroke
            NSColor.black.setStroke()
            path.stroke()

            let base = NSFont.systemFont(ofSize: 7, weight: .bold)
            let condensed = base.fontDescriptor.withSymbolicTraits(.condensed)
            let font = NSFont(descriptor: condensed, size: 7) ?? base
            let attributed = NSAttributedString(string: "OCR", attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
                .kern: -0.9,
            ])
            let size = attributed.size()
            attributed.draw(at: NSPoint(x: (design.width - size.width) / 2,
                                        y: (design.height - size.height) / 2))
            ctx.restoreGraphicsState()
            return true
        }
        image.isTemplate = true   // 颜色交给 contentTintColor，和 SF Symbol 按钮一致
        return image
    }

    private static func makeIconButton(_ symbol: String, _ name: String,
                                       tint: NSColor = .labelColor,
                                       _ handler: @escaping () -> Void) -> IconButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        return makeImageButton(image ?? NSImage(), name, tint: tint, handler)
    }

    /// 自绘图标版的按钮（OCR 用；其余按钮走 SF Symbol）。
    private static func makeImageButton(_ image: NSImage, _ name: String,
                                        tint: NSColor = .labelColor,
                                        _ handler: @escaping () -> Void) -> IconButton {
        let button = IconButton(frame: .zero)
        button.image = image
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
        // 玻璃底本身有厚度，内边距比旧色块版稍大，控件才不显得贴边。
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        // Tools
        let pen = Self.makeIconButton("pencil", "画笔") { [weak self] in self?.setTool(.pen) }
        let roundedRect = Self.makeIconButton("squareshape", "圆角矩形") { [weak self] in self?.setTool(.roundedRect) }
        let arrow = Self.makeIconButton("arrow.up.right", "箭头") { [weak self] in self?.setTool(.arrow) }
        let text = Self.makeLetterIconButton("T", "文字") { [weak self] in self?.setTool(.text) }
        let undo = Self.makeIconButton("arrow.uturn.backward", "撤销") { [weak self] in self?.undoLastAnnotation() }
        undo.isEnabled = false
        toolButtons = [.pen: pen, .roundedRect: roundedRect, .arrow: arrow, .text: text]
        undoButton = undo
        stack.addArrangedSubview(pen)
        stack.addArrangedSubview(roundedRect)
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
        stack.addArrangedSubview(Self.makeIconButton("pin", "钉在桌面") { [weak self] in
            self?.onFinalAction?("pin")
        })
        stack.addArrangedSubview(Self.makeIconButton("xmark", "取消", tint: .systemRed) { [weak self] in
            self?.onCancel?()
        })
        // OCR 用自绘图标（框里写 OCR），比 SF Symbol 的取景框图形更一眼可辨。
        stack.addArrangedSubview(Self.makeImageButton(Self.ocrGlyphIcon(), "OCR 文字识别") { [weak self] in
            self?.onFinalAction?("ocr")
        })
        for (symbol, name, action) in [("square.and.arrow.down", "保存", "save"),
                                       ("doc.on.doc", "复制", "copy")] {
            stack.addArrangedSubview(Self.makeIconButton(symbol, name) { [weak self] in
                self?.onFinalAction?(action)
            })
        }

        // 底：macOS 26+ 走原生液态玻璃（NSGlassEffectView，实时折射 + 自适应当前
        // 外观），旧系统由 GlassBackdrop 退回半透明色块。投影在容器上，让工具条
        // 从截图上浮起来。
        return GlassBackdrop.wrap(stack, cornerRadius: 12)
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

    // MARK: - 开发者验证钩子（默认关闭，见 AppDelegate 顶部的 defaults 说明）
    // 「框选」这一步必须人手完成，自动化看不到工具条 —— 用这个钩子直接摆一个假选区，
    // 配合 WAYCAST_NO_CAPTURE（屏幕内容换成纯灰）就能无人值守地核对工具条与撤销。
    func debugSelect(_ rect: NSRect, annotate: Bool) {
        selectionRect = rect
        phase = .pendingAction
        if annotate {
            // 一笔曲线 + 一个箭头：正好覆盖「画笔」与「箭头」两类标注。
            let pts = stride(from: 0, through: 10, by: 1).map { i -> NSPoint in
                let t = CGFloat(i) / 10
                return NSPoint(x: rect.minX + 30 + t * 160,
                               y: rect.minY + 40 + sin(t * .pi) * 50)
            }
            annotations = [
                .stroke(PenStroke(points: pts, color: .systemRed, width: Self.penWidth)),
                .arrow(ArrowAnnotation(start: NSPoint(x: rect.minX + 220, y: rect.minY + 50),
                                       end: NSPoint(x: rect.minX + 330, y: rect.minY + 130),
                                       color: .systemRed, width: Self.penWidth)),
            ]
        }
        needsDisplay = true
        refreshUndoState()
        showActionBar(below: rect)
    }

    /// 给外部（控制器）读一下当前标注数，用于验证撤销是否生效。
    var debugAnnotationCount: Int { annotations.count }

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

    /// 选区之外区域的遮罩强度（0…1）。会话开始时从设置里快照一次，
    /// 免得在 120 Hz 的重绘里反复读 UserDefaults。
    /// 改强度：设置界面里的「选区外遮罩」，或
    /// `defaults write com.waycast.macos captureDimOpacity -float 0.6`。
    private let dimStrength: CGFloat = CGFloat(AppSettings.shared.captureDimOpacity)

    /// 0 = identical to the live screen, 1 = fully dimmed (dimStrength black).
    private var dimProgress: CGFloat = 0
    private var dimTimer: Timer?
    private var dimStart: CFTimeInterval?

    /// Called right after the panel becomes visible.
    ///
    /// 这里以前是「首帧 dimProgress = 0（与实时屏幕逐像素一致）→ 200ms / 120Hz 渐显」。
    /// 想法是"别闪"，代价却是**感知延迟**：屏幕内容静止时，冻结帧和实时画面一模一样，
    /// 用户看不出任何变化，只能等遮罩慢慢浮上来 —— 手感就成了"按了没反应"。
    /// 现在首帧直接带 30% 遮罩，再用 120ms / 60Hz 收尾：一进来就能看见，
    /// 又不会亮暗跳变。顺带把每秒 120 次的全屏重绘降到 60 次。
    func startDimFade() {
        dimTimer?.invalidate()
        dimProgress = Self.dimHeadStart
        dimStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepDimFade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer
    }

    private static let dimHeadStart: CGFloat = 0.3
    private static let dimFadeDuration: CFTimeInterval = 0.12

    private func stepDimFade() {
        guard let start = dimStart else { return }
        let t = min(1, (CACurrentMediaTime() - start) / Self.dimFadeDuration)
        let eased = 1 - pow(1 - t, 3) // ease-out cubic
        dimProgress = Self.dimHeadStart + (1 - Self.dimHeadStart) * eased
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

        // Dim everything outside the selection; the hole below re-draws the
        // untouched frame for the region being picked, so it stays bright.
        // Strength comes from settings (default 0.45): a strong scrim is what
        // makes the selection read as "the part that will be captured".
        // dimProgress fades 0→1 after the session starts (first frame stays
        // pixel-identical to the live screen), so the arrival reads as smooth,
        // not a flash.
        NSColor.black.withAlphaComponent(dimStrength * dimProgress).setFill()
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

        // Corner knobs: only while the border is resizable (no tool active).
        if phase == .pendingAction, tool == .none {
            drawResizeHandles(for: hole)
        }

        // Annotations (also draw the in-progress stroke live).
        context.saveGState()
        context.clip(to: hole)
        drawAnnotations()
        if let stroke = currentStroke { drawStroke(stroke) }
        if let arrow = currentArrow { drawArrow(arrow) }
        if let rr = currentRoundedRect { drawRoundedRect(rr) }
        // 悬停标注的提示框：黑+白双层虚线，截图底色深浅都看得见。
        if phase == .pendingAction, tool == .none, draggingAnnotation == nil,
           let idx = hoveredAnnotationIndex, annotations.indices.contains(idx) {
            let b = annotationBounds(annotations[idx]).insetBy(dx: -5, dy: -5)
            let dashed = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
            dashed.setLineDash([4, 3], count: 2, phase: 0)
            dashed.lineWidth = 2.5
            NSColor.black.withAlphaComponent(0.55).setStroke()
            dashed.stroke()
            let inner = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
            inner.setLineDash([4, 3], count: 2, phase: 0)
            inner.lineWidth = 1
            NSColor.white.withAlphaComponent(0.9).setStroke()
            inner.stroke()
        }
        context.restoreGState()

        // 滚轮调粗细/字号时的短暂提示（画在选区顶部内侧，不挡工具栏）。
        if let hint = sizeHint, let rect = selectionRect {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let textSize = (hint as NSString).size(withAttributes: attrs)
            let box = NSRect(x: rect.midX - textSize.width / 2 - 9,
                             y: rect.maxY - 26,
                             width: textSize.width + 18, height: 19)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 9.5, yRadius: 9.5).fill()
            hint.draw(at: NSPoint(x: box.minX + 9, y: box.minY + 3.5), withAttributes: attrs)
        }
    }

    private func drawAnnotations() {
        for annotation in annotations {
            switch annotation {
            case .stroke(let stroke): drawStroke(stroke)
            case .text(let text): drawText(text)
            case .arrow(let arrow): drawArrow(arrow)
            case .roundedRect(let rr): drawRoundedRect(rr)
            }
        }
    }

    private func drawRoundedRect(_ rr: RoundedRectAnnotation) {
        guard rr.rect.width > 1, rr.rect.height > 1 else { return }
        let radius = min(10, rr.rect.width / 2, rr.rect.height / 2)
        let path = NSBezierPath(roundedRect: rr.rect, xRadius: radius, yRadius: radius)
        path.lineWidth = rr.width
        path.lineJoinStyle = .round
        rr.color.setStroke()
        path.stroke()
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
            case .roundedRect(var rr):
                rr.rect = rr.rect.offsetBy(dx: d.x, dy: d.y)
                return .roundedRect(rr)
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

    // MARK: Annotation hit-testing / zoom

    /// 标注的命中范围（外扩到含线宽，否则细线几乎点不中）。文字按当前字体的
    /// 实际排版尺寸算。
    private func annotationBounds(_ annotation: CaptureAnnotation) -> NSRect {
        switch annotation {
        case .stroke(let s):
            guard let first = s.points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in s.points.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let pad = s.width / 2 + 3
            return NSRect(x: minX - pad, y: minY - pad,
                          width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
        case .text(let t):
            let size = (t.text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: t.fontSize, weight: .medium)])
            return NSRect(x: t.point.x, y: t.point.y, width: size.width, height: size.height)
        case .arrow(let a):
            let head = max(11, a.width * 3.2)
            let pad = a.width + head
            return NSRect(x: min(a.start.x, a.end.x) - pad, y: min(a.start.y, a.end.y) - pad,
                          width: abs(a.end.x - a.start.x) + pad * 2,
                          height: abs(a.end.y - a.start.y) + pad * 2)
        case .roundedRect(let rr):
            let pad = rr.width / 2 + 3
            return rr.rect.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// 鼠标下的标注，后画的优先（视觉上在最上面）。
    private func annotationIndex(at point: NSPoint) -> Int? {
        for i in annotations.indices.reversed()
        where annotationBounds(annotations[i]).contains(point) {
            return i
        }
        return nil
    }

    /// 以元素自身中心为锚缩放（文字以落点为锚 —— 位置归拖动管，缩放只管大小）。
    /// 线条粗细/字号跟着一起变，看起来才是「同一个标记变大了」而不是重新画。
    private static func scaled(_ annotation: CaptureAnnotation, by f: CGFloat) -> CaptureAnnotation {
        func scalePoint(_ p: NSPoint, around c: NSPoint) -> NSPoint {
            NSPoint(x: c.x + (p.x - c.x) * f, y: c.y + (p.y - c.y) * f)
        }
        func clampWidth(_ w: CGFloat) -> CGFloat { min(max(w * f, 1.5), 48) }
        switch annotation {
        case .stroke(var s):
            var center = NSPoint.zero
            if let first = s.points.first {
                var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
                for p in s.points {
                    minX = min(minX, p.x); maxX = max(maxX, p.x)
                    minY = min(minY, p.y); maxY = max(maxY, p.y)
                }
                center = NSPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            }
            s.points = s.points.map { scalePoint($0, around: center) }
            s.width = clampWidth(s.width)
            return .stroke(s)
        case .text(var t):
            t.fontSize = min(max(t.fontSize * f, 9), 200)
            return .text(t)
        case .arrow(var a):
            let center = NSPoint(x: (a.start.x + a.end.x) / 2, y: (a.start.y + a.end.y) / 2)
            a.start = scalePoint(a.start, around: center)
            a.end = scalePoint(a.end, around: center)
            a.width = clampWidth(a.width)
            return .arrow(a)
        case .roundedRect(var rr):
            let center = NSPoint(x: rr.rect.midX, y: rr.rect.midY)
            rr.rect = NSRect(x: center.x - rr.rect.width * f / 2,
                             y: center.y - rr.rect.height * f / 2,
                             width: max(rr.rect.width * f, 4),
                             height: max(rr.rect.height * f, 4))
            rr.width = clampWidth(rr.width)
            return .roundedRect(rr)
        }
    }

    /// 工具激活时滚轮调「下一个标注」的默认粗细 / 字号。
    private func adjustActiveToolSize(by factor: CGFloat) {
        switch tool {
        case .pen:
            activePenWidth = min(max(activePenWidth * factor, 2), 40)
            sizeHint = "画笔 \(Int(activePenWidth.rounded()))pt"
        case .arrow:
            activePenWidth = min(max(activePenWidth * factor, 2), 40)
            sizeHint = "箭头 \(Int(activePenWidth.rounded()))pt"
        case .roundedRect:
            activePenWidth = min(max(activePenWidth * factor, 2), 40)
            sizeHint = "矩形 \(Int(activePenWidth.rounded()))pt"
        case .text:
            activeFontSize = min(max(activeFontSize * factor, 10), 120)
            sizeHint = "文字 \(Int(activeFontSize.rounded()))pt"
        case .none:
            return
        }
        scheduleSizeHintDismiss()
        needsDisplay = true
    }

    private func scheduleSizeHintDismiss() {
        sizeHintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.sizeHint = nil
                self?.needsDisplay = true
            }
        }
        sizeHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: Resize handles

    /// Which rect edges (if any) sit within `handleTolerance` of the point.
    /// Edges are hit even slightly OUTSIDE the rect, so all four corners are
    /// grabbable from any direction.
    private func resizeEdges(at point: NSPoint, in rect: NSRect) -> ResizeEdges? {
        let tol = Self.handleTolerance
        var edges: ResizeEdges = []
        if abs(point.x - rect.minX) <= tol { edges.insert(.minX) }
        else if abs(point.x - rect.maxX) <= tol { edges.insert(.maxX) }
        if abs(point.y - rect.minY) <= tol { edges.insert(.minY) }
        else if abs(point.y - rect.maxY) <= tol { edges.insert(.maxY) }
        return edges.isEmpty ? nil : edges
    }

    /// Re-anchors the grabbed edges of `original` to `point`, keeping the rect
    /// at least `minSelectionSize` on each axis and inside the view bounds.
    private func resizedRect(_ original: NSRect, edges: ResizeEdges, to point: NSPoint) -> NSRect {
        var r = original
        let minSize = Self.minSelectionSize
        if edges.contains(.minX) {
            r.origin.x = min(max(point.x, bounds.minX), original.maxX - minSize)
            r.size.width = original.maxX - r.origin.x
        } else if edges.contains(.maxX) {
            let maxX = max(min(point.x, bounds.maxX), original.minX + minSize)
            r.size.width = maxX - r.origin.x
        }
        if edges.contains(.minY) {
            r.origin.y = min(max(point.y, bounds.minY), original.maxY - minSize)
            r.size.height = original.maxY - r.origin.y
        } else if edges.contains(.maxY) {
            let maxY = max(min(point.y, bounds.maxY), original.minY + minSize)
            r.size.height = maxY - r.origin.y
        }
        return r.intersection(bounds)
    }

    /// Directional cursor for a handle zone; corner zones use the crosshair
    /// (AppKit has no public diagonal resize cursors).
    private func applyCursor(for edges: ResizeEdges?) {
        guard let edges else { NSCursor.arrow.set(); return }
        let vertical = edges.contains(.minY) || edges.contains(.maxY)
        let horizontal = edges.contains(.minX) || edges.contains(.maxX)
        if vertical && horizontal {
            NSCursor.crosshair.set()
        } else if horizontal {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.resizeUpDown.set()
        }
    }

    /// Corner knobs on the selection border (drawn when no tool is active).
    private func drawResizeHandles(for rect: NSRect) {
        let size: CGFloat = 8
        let corners = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        for p in corners {
            let r = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            NSColor.white.setFill()
            NSBezierPath(rect: r).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: r)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

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

    /// 覆盖层真正显形时回调一次（诊断/测延迟用；生产路径为 nil）。
    var onPresented: (() -> Void)?

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

    var isRunning: Bool { !panels.isEmpty || shellActive }

    /// 空壳已经挂上、还在等抓帧的窗口期（用来挡住这期间的第二下按键）。
    private var shellActive = false

    /// 诊断开关：关掉空壳做 A/B（默认开）。
    var shellEnabled = true

    // MARK: - 诊断埋点（只在 WAYCAST_CAPTURE_BENCH 打开时记录，开销可忽略）

    /// 本次会话各阶段相对 `start()` 的毫秒数。用来回答"按完键之后时间花在哪"。
    private(set) var phaseMarks: [(String, Double)] = []
    private static let benchOn = UserDefaults.standard.bool(forKey: "WAYCAST_CAPTURE_BENCH")
    private var sessionT0: CFTimeInterval = 0

    private func mark(_ name: String) {
        guard Self.benchOn else { return }
        phaseMarks.append((name, (CACurrentMediaTime() - sessionT0) * 1000))
    }

    /// 开发者钩子：抓完帧后直接摆一个假选区（居中，占屏幕 fraction），可选预置两个
    /// 标注。框选必须人手完成，自动化验证（截图核对工具栏外观 / 验 ⌘Z）看不到工具条。
    ///   defaults write com.waycast.macos WAYCAST_AUTO_CAPTURE_SELECT -float 0.45
    ///   defaults write com.waycast.macos WAYCAST_AUTO_ANNOTATE -bool true
    func debugSelect(fraction: CGFloat, annotate: Bool) {
        guard let view = views.first else { return }
        let b = view.bounds
        view.debugSelect(NSRect(x: b.midX - b.width * fraction / 2,
                                y: b.midY - b.height * fraction / 2,
                                width: b.width * fraction, height: b.height * fraction),
                         annotate: annotate)
    }

    /// 当前有多少个标注（验证撤销用）。
    var debugAnnotationCount: Int { views.first?.debugAnnotationCount ?? -1 }

    /// 覆盖层的当前第一响应者（验证键盘链路用）。
    var debugFirstResponder: NSResponder? {
        panels.first(where: { $0.isKeyWindow })?.firstResponder
    }

    /// 把当前标注数追加写一行到文件（GUI app 的 stdout 看不到，只能写文件）。
    func debugLog(_ line: String, to path: String) {
        let previous = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (previous + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func start() {
        sessionT0 = CACurrentMediaTime()
        phaseMarks = []
        mark("start() 进入")
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            Toast.show("截图需要「屏幕录制」权限，请在弹窗中允许")
            return
        }
        presentShells()
        mark("空壳显形（十字光标已生效）")
        Task { await runSession() }
    }

    /// 挂空壳：不画像素、不压暗，纯粹为了立刻把光标换成十字并让面板可交互。
    private func presentShells() {
        guard shellEnabled else { return }
        for entry in panelPool {
            let shell = CaptureShellView(frame: NSRect(origin: .zero, size: entry.frame.size))
            entry.panel.contentView = shell
            entry.panel.ignoresMouseEvents = false
            entry.panel.alphaValue = 1
            shell.window?.invalidateCursorRects(for: shell)
        }
        shellActive = true
        NSCursor.crosshair.set()
    }

    /// 仅供诊断：只挂空壳、不启动会话（用来验证空壳不污染抓帧）。
    func debugPresentShellsOnly() { presentShells() }

    private func runSession() async {
        mark("runSession 开始（Task 调度）")
        let screens: [FrozenScreen]
        do {
            screens = try await FrozenCapture.captureAllScreens()
        } catch {
            Toast.show("截图失败：无法捕获屏幕（权限或显示状态变化）")
            teardown()
            return
        }
        mark("抓帧完成")
        guard !screens.isEmpty else {
            teardown()
            return
        }

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
        mark("视图/面板就绪")

        // Flip visibility in place — no window open event, no animation.
        for panel in panels {
            panel.ignoresMouseEvents = false
            panel.alphaValue = 1
        }
        // 立刻把光标换成十字：这是零成本的"我按到了"信号，遮罩还没浮上来时
        // 用户也能马上确认截图态已进入。
        NSCursor.crosshair.set()
        for view in views { view.startDimFade() }
        mark("已显形（alpha 翻好）")

        // Anchor keyboard focus on the panel under the mouse (Esc needs the
        // responder chain).
        let mouse = NSEvent.mouseLocation
        let anchor = panels.first { $0.frame.contains(mouse) } ?? panels.first
        anchor?.makeKeyAndOrderFront(nil)
        mark("取到键盘焦点")
        if let view = anchor?.contentView { anchor?.makeFirstResponder(view) }
        mark("第一响应者就位")
        armKeyWindowWatchdog(for: anchor)
        onPresented?()
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
        // 60ms 一次（原来 150ms）：首次重试越快，偶发的"按键后卡一下"越短。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: Decisions

    private func finalAction(_ action: String, from view: CaptureSelectionView) {
        let anchorFrame = view.window?.frame ?? .zero
        let image = view.composeFinalImage()
        // Grab the selection's global position BEFORE teardown for pinning.
        var pinRect: NSRect?
        if action == "pin", let rect = view.selectionRect, let win = view.window {
            pinRect = win.convertToScreen(view.convert(rect, to: nil))
        }
        teardown()
        guard let image else {
            Toast.show("截图失败")
            return
        }
        switch action {
        case "copy":
            Self.copyImage(image)
        case "pin":
            guard let pinRect else { return }
            PinnedShotController.shared.pin(image: image, screenRect: pinRect)
        case "ocr":
            // 识别与展示都交给结果窗口 —— 它会先显示「正在识别…」，识别完填充，
            // 并且允许当场换语言/排版重算。
            OcrResultWindowController.shared.show(image: image, sourceName: "截图", near: anchorFrame)
        case "save":
            let name = "截图 \(Self.dateFormatter.string(from: Date())).png"
            ImageSaveSupport.saveWithPanel(image, defaultName: name)
        default:
            break
        }
    }

    /// Legacy direct-capture path, now only used for Shift+click OCR and as
    /// the cross-display fallback (plain click enters editing mode instead —
    /// see CaptureSelectionView.mouseUp).
    private func windowClicked(hit: WindowHitTestResult, ocr: Bool) {
        let windowID = hit.windowID
        let ownerPID = hit.ownerPID
        let anchorFrame = hit.bounds
        teardown()
        Task { @MainActor in
            do {
                let image = try await FrozenCapture.captureWindow(windowID: windowID, ownerPID: ownerPID)
                if ocr {
                    OcrResultWindowController.shared.show(image: image, sourceName: "窗口截图", near: anchorFrame)
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
        shellActive = false
        for view in views {
            view.onFinalAction = nil
            view.onWindowClicked = nil
            view.onCancel = nil
            view.stopDimFade()
            view.dismissActionBar()
        }
        // 对整个池复位，而不是只复位本次 panels —— 空壳阶段（已经显形、
        // 但抓帧还没回来）失败时，panels 还是空的，只复位 panels 会把
        // "透明但吃鼠标"的覆盖层留在屏幕上，把所有点击全吞掉。
        for entry in panelPool {
            entry.panel.delegate = nil
            // Hide in place: keep the window ordered front but transparent and
            // mouse-transparent. Never orderOut — re-fronting a window plays
            // Tahoe's zoom animation again.
            entry.panel.ignoresMouseEvents = true
            entry.panel.alphaValue = 0
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
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
