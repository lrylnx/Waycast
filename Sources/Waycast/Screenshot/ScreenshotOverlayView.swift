import Cocoa
import Carbon.HIToolbox

/// Full-screen flipped overlay that renders the captured desktop,
/// the selection and all annotations, and handles all mouse input.
final class ScreenshotOverlayView: NSView {
    let model: ScreenshotModel
    var onSelectionChanged: ((CGRect) -> Void)?
    var onFinish: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Fires once when a fresh drag produces a valid box (mouse-up).
    var onSelectionSettled: (() -> Void)?
    /// True only while dragging out a BRAND-NEW selection box; the toolbar
    /// hides during that (so it doesn't chase the box) but stays visible for
    /// annotation drags / clicks inside an existing selection.
    var isCreatingSelection: Bool {
        if case .newSelection = dragMode { return true }
        return false
    }

    private enum DragMode {
        case none, newSelection, moveSelection, resize(Int), annotate
    }

    /// Selection state captured at mouseDown so a stray CLICK (no drag)
    /// outside the box can restore it instead of wiping it.
    private var selectionBeforeClick = CGRect.zero
    private var hasSelectionBeforeClick = false

    private var dragMode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var selectionStart: CGRect = .zero
    private var liveAnnotation: Annotation?
    private var textEditor: NSTextField?
    private var fieldEditor: NSTextView?
    private var editingAnnotation: Annotation?
    /// Deferred "give focus back to the overlay" work. MUST be cancelled when
    /// a new text edit begins, otherwise it fires after beginTextEditing and
    /// steals first responder from the fresh field (second click beeps).
    private var focusReturnWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        model = ScreenshotModel()
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let image = model.desktopImage else { return }

        // 1. Desktop image. Draw the CGImage directly with a manual flip —
        // allocating + drawing an NSImage every frame made drag-selection
        // lag badly (box only appeared when the mouse stopped).
        ctx.saveGState()
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()

        let sel = model.selection

        // 2. Dim outside the selection.
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(model.hasSelection ? 0.45 : 0.25).cgColor)
        if model.hasSelection {
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: sel.minY))
            ctx.fill(CGRect(x: 0, y: sel.maxY, width: bounds.width, height: bounds.height - sel.maxY))
            ctx.fill(CGRect(x: 0, y: sel.minY, width: sel.minX, height: sel.height))
            ctx.fill(CGRect(x: sel.maxX, y: sel.minY, width: bounds.width - sel.maxX, height: sel.height))
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        // 3. Annotations, clipped to selection.
        if model.hasSelection, let rc = renderContext {
            // Live-sync the in-progress text annotation from the field editor
            // (includes IME marked text), so typing shows instantly.
            if let editing = editingAnnotation {
                editing.text = fieldEditor?.string ?? ""
            }
            ctx.saveGState()
            ctx.clip(to: sel)
            for a in model.annotations { AnnotationRenderer.draw(a, ctx: ctx, rc: rc) }
            if let live = liveAnnotation { AnnotationRenderer.draw(live, ctx: ctx, rc: rc) }
            // Caret for the text being edited.
            if let editing = editingAnnotation, let p = editing.points.first {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: editing.fontSize, weight: .semibold)]
                let w = (editing.text as NSString).size(withAttributes: attrs).width
                ctx.setStrokeColor(editing.color.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: p.x + w + 1, y: p.y))
                ctx.addLine(to: CGPoint(x: p.x + w + 1, y: p.y + editing.fontSize * 1.15))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        // 4. Selection border, handles and size label.
        if model.hasSelection {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
            for p in handlePoints(of: sel) {
                let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(NSColor.systemBlue.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(r)
            }
            let label = "\(Int(sel.width)) × \(Int(sel.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.6)
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: CGPoint(x: sel.minX, y: sel.minY - size.height - 4),
                                     withAttributes: attrs)
            ctx.restoreGState()
        }
    }

    private func handlePoints(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
         CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private lazy var pixelatedImage: CGImage? = {
        guard let img = model.desktopImage else { return nil }
        return ImageProcessor.pixelate(img, blockSize: 12 * model.desktopScale)
    }()

    private var renderContext: AnnotationRenderer.Context? {
        guard let desktop = model.desktopImage else { return nil }
        return AnnotationRenderer.Context(desktop: desktop,
                                          pixelated: pixelatedImage,
                                          viewSize: bounds.size)
    }

    // MARK: - Mouse

    private func viewPoint(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let p = viewPoint(from: event)

        if event.clickCount == 2, model.tool == .select,
           model.hasSelection, model.selection.contains(p) {
            commitTextEdit()
            onDoubleClick?()
            return
        }

        if model.tool == .text, model.hasSelection, model.selection.contains(p) {
            beginTextEditing(at: p)
            return
        }

        // Selection handles work with ANY tool active — after annotating with
        // rect/pen/etc. the user must still be able to resize the box.
        if model.hasSelection, let h = handleIndex(at: p) {
            dragMode = .resize(h)
            dragStart = p
            selectionStart = model.selection
            needsDisplay = true
            return
        }

        if !model.hasSelection || model.tool == .select {
            if model.selection.insetBy(dx: -6, dy: -6).contains(p) {
                dragMode = .moveSelection
                dragStart = p
                selectionStart = model.selection
            } else {
                dragMode = .newSelection
                dragStart = p
                selectionBeforeClick = model.selection
                hasSelectionBeforeClick = model.hasSelection
                model.selection = CGRect(origin: p, size: .zero)
                // Stays false until the drag produces a real box, so the
                // toolbar only appears after an actual selection exists.
                model.hasSelection = false
                onSelectionChanged?(model.selection)   // hide toolbar now
            }
            needsDisplay = true
            return
        }

        // Clicking OUTSIDE the selection with an annotation tool active
        // cancels that tool and falls back to move/select (toolbar highlight
        // follows via the model.tool publisher).
        if model.hasSelection, !model.selection.insetBy(dx: -6, dy: -6).contains(p),
           model.tool != .select {
            commitTextEdit()
            model.tool = .select
            needsDisplay = true
            return
        }

        // Annotation drawing
        let color = model.color
        let lw = model.lineWidth
        switch model.tool {
        case .rect:   liveAnnotation = Annotation(kind: .rect, points: [p, p], color: color, lineWidth: lw)
        case .pen:    liveAnnotation = Annotation(kind: .pen, points: [p], color: color, lineWidth: lw)
        case .arrow:  liveAnnotation = Annotation(kind: .arrow, points: [p, p], color: color, lineWidth: lw)
        case .mosaic: liveAnnotation = Annotation(kind: .mosaic, points: [p], color: color, lineWidth: lw)
        default: break
        }
        dragMode = .annotate
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = viewPoint(from: event)
        switch dragMode {
        case .newSelection:
            let r = CGRect(points: [dragStart, p])
            model.selection = r
            // Must flip true DURING the drag, otherwise draw() (which gates the
            // box + dim on hasSelection) shows nothing until the mouse stops.
            model.hasSelection = r.width > 3 && r.height > 3
        case .moveSelection:
            let dx = p.x - dragStart.x, dy = p.y - dragStart.y
            var r = selectionStart.offsetBy(dx: dx, dy: dy)
            r.origin.x = max(0, min(r.origin.x, bounds.width - r.width))
            r.origin.y = max(0, min(r.origin.y, bounds.height - r.height))
            model.selection = r
        case .resize(let idx):
            model.selection = resizedRect(selectionStart, handle: idx, to: p)
        case .annotate:
            guard let live = liveAnnotation else { return }
            switch live.kind {
            case .rect, .arrow: live.points[1] = p
            case .pen, .mosaic: live.points.append(p)
            case .text: break
            }
        case .none:
            break
        }
        onSelectionChanged?(model.selection)
        needsDisplay = true
    }

    /// handle indices follow handlePoints order: 0..7 = TL, T, TR, R, BR, B, BL, L
    private func resizedRect(_ r0: CGRect, handle idx: Int, to p: CGPoint) -> CGRect {
        var minX = r0.minX, minY = r0.minY, maxX = r0.maxX, maxY = r0.maxY
        switch idx {
        case 0: minX = p.x; minY = p.y
        case 1: minY = p.y
        case 2: maxX = p.x; minY = p.y
        case 3: maxX = p.x
        case 4: maxX = p.x; maxY = p.y
        case 5: maxY = p.y
        case 6: minX = p.x; maxY = p.y
        case 7: minX = p.x
        default: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
            .intersection(bounds)
    }

    private func handleIndex(at p: CGPoint) -> Int? {
        guard model.hasSelection else { return nil }
        for (i, h) in handlePoints(of: model.selection).enumerated()
        where abs(p.x - h.x) < 6 && abs(p.y - h.y) < 6 { return i }
        return nil
    }

    override func mouseUp(with event: NSEvent) {
        // Clear the mode BEFORE notifying: positionToolbar() reads
        // isCreatingSelection, and with the old `defer` it still saw
        // .newSelection on mouse-up, so the toolbar stayed hidden until the
        // next click.
        let mode = dragMode
        dragMode = .none
        if case .annotate = mode, let live = liveAnnotation {
            liveAnnotation = nil
            let r = live.boundingRect
            if (live.kind == .rect || live.kind == .arrow) && r.width < 2 && r.height < 2 {
                needsDisplay = true
                return
            }
            model.annotations.append(live)
        }
        if case .newSelection = mode {
            let r = model.selection
            if r.width < 3 || r.height < 3 {
                // A click (no real drag): keep whatever selection existed
                // before — clicking blank space must NOT wipe the box.
                // (Before any box ever existed, prev was empty, so stray
                // clicks still do nothing.)
                model.selection = selectionBeforeClick
                model.hasSelection = hasSelectionBeforeClick
            } else {
                model.hasSelection = true
                onSelectionSettled?()
            }
        }
        onSelectionChanged?(model.selection)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard model.tool != .select else { return }
        let delta: CGFloat = event.scrollingDeltaY > 0 ? 1 : (event.scrollingDeltaY < 0 ? -1 : 0)
        guard delta != 0 else { return }
        model.adjustSize(by: delta)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onFinish?()
            return
        }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            commitTextEdit()
            onDoubleClick?()
            return
        }
        if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_ANSI_Z) {
            commitTextEdit()
            model.undo()
            needsDisplay = true
            return
        }
        if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_ANSI_C) {
            commitTextEdit()
            onDoubleClick?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Text editing
    //
    // SnapPin approach: the NSTextField is a fully TRANSPARENT input sink
    // (no background, invisible text); the live string — including IME
    // marked text — is rendered by draw() through the same pipeline as the
    // committed annotation, so there is no black box and no jump on commit.

    private func beginTextEditing(at p: CGPoint) {
        commitTextEdit()
        // The commit above scheduled a focus-return; this new edit owns focus
        // now, so cancel it or it will steal first responder in ~10ms.
        focusReturnWork?.cancel()
        focusReturnWork = nil
        let a = Annotation(kind: .text, points: [p], color: model.color,
                           lineWidth: 1, text: "", fontSize: model.fontSize)
        model.annotations.append(a)
        editingAnnotation = a

        let height = max(28, a.fontSize * 1.6)
        let maxWidth = max(140, min(480, model.selection.maxX - p.x - 4))
        let field = NSTextField(frame: CGRect(x: p.x, y: p.y - (height - a.fontSize * 1.35) / 2,
                                              width: maxWidth, height: height))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)
        field.textColor = .clear          // invisible: draw() renders the text
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.delegate = self
        addSubview(field)
        textEditor = field
        needsDisplay = true

        // The app is an accessory (LSUIElement) and may have been deactivated
        // since the session started; re-activate so the field editor receives
        // keystrokes.
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(field)
        }
        // Take over the field editor to observe IME marked text live.
        if let editor = field.currentEditor() as? NSTextView {
            editor.delegate = self
            fieldEditor = editor
        }
    }

    func commitTextEdit() {
        guard let field = textEditor, let a = editingAnnotation else {
            textEditor = nil; fieldEditor = nil; editingAnnotation = nil
            return
        }
        a.text = (fieldEditor?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        fieldEditor?.delegate = nil
        fieldEditor = nil
        field.removeFromSuperview()
        textEditor = nil
        editingAnnotation = nil
        if a.text.isEmpty {
            model.annotations.removeAll { $0.id == a.id }
        }
        // Return keyboard control to the overlay so ⌘Z / Esc keep working.
        // MUST defer (commit often runs INSIDE a mouse-down aimed at a toolbar
        // button; an immediate first-responder change steals that click), and
        // MUST be cancellable (a new beginTextEditing clears it, else the
        // deferred block steals focus from the fresh field -> second click
        // beeps).
        focusReturnWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.window?.firstResponder is NSTextView {
                self.window?.makeFirstResponder(self)
            }
        }
        focusReturnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
        needsDisplay = true
    }
}

extension ScreenshotOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEdit()
    }

    /// Enter commits, Esc cancels ONLY the text edit (not the whole session).
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            commitTextEdit()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            commitTextEdit()
            return true
        }
        return false
    }
}

extension ScreenshotOverlayView: NSTextViewDelegate {
    /// Field-editor changes (incl. IME marked text) -> live re-render.
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === fieldEditor else { return }
        needsDisplay = true
    }
}
