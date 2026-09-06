import Cocoa

/// Small floating panel showing OCR result text.
///
/// Uses the canonical NSScrollView + NSTextView(frame:textContainer:) pairing
/// with widthTracksTextView enabled. The previous version built the text view
/// with the no-arg init, whose text container never tracked the view width —
/// the string was there (copy worked) but laid out at zero width, so the
/// window rendered blank.
final class OCRResultWindow: NSWindow {
    static let shared = OCRResultWindow()

    private let textView: NSTextView
    private let scrollView: NSScrollView
    private var copyTarget: String = ""

    private init() {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Canonical construction: NSTextView(frame:) creates a matching text
        // container; we then make its width track the scroll view.
        textView = NSTextView(frame: scrollView.bounds)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width,
                                                       height: .greatestFiniteMagnitude)
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        scrollView.documentView = textView

        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        title = "OCR 识别结果"
        isReleasedWhenClosed = false
        // The screenshot overlay is torn down before OCR results appear, so a
        // normal floating level suffices and stays interactive.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 380, height: 240)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 340))

        let hint = NSTextField(labelWithString: "可直接编辑 · 选中文字 ⌘C 复制")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 14, y: 312, width: 240, height: 14)
        hint.autoresizingMask = [.minYMargin]
        container.addSubview(hint)

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyAll(_:)))
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: 344, y: 306, width: 82, height: 26)
        copy.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(copy)

        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        contentView = container
    }

    func show(text: String) {
        copyTarget = text
        textView.string = text
        textView.textColor = .textColor
        // Force the container to the current width and lay out immediately —
        // setting a string before the container has a positive width is what
        // previously left the window blank.
        textView.textContainer?.containerSize =
            NSSize(width: max(scrollView.contentSize.width, 100),
                   height: .greatestFiniteMagnitude)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.needsDisplay = true
        let lines = text.split(separator: "\n").count
        title = "OCR 识别结果（\(lines) 行）"
        positionInTopRightQuadrant()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(textView)
    }

    /// Center of the top-right quarter of the screen (not glued to the corner).
    private func positionInTopRightQuadrant() {
        let screen = ScreenUtils.screenContainingMouse() ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { center(); return }
        let size = frame.size
        let x = vf.midX + (vf.maxX - vf.midX - size.width) / 2
        let y = vf.midY + (vf.maxY - vf.midY - size.height) / 2
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    @objc private func copyAll(_ sender: Any) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string.isEmpty ? copyTarget : textView.string,
                                       forType: .string)
        Toast.show("已复制全部文字")
    }
}
