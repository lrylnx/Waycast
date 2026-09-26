//
//  OcrResultWindow.swift
//  Waycast
//
//  OCR 结果窗口：可编辑、可选择性复制，并且能**当场换语言/排版重识别**
//  —— 识别错了不用重新截图。
//
//  窗口自己负责跑识别（调用方只交出图片），这样「重识别」这件事内聚在这里：
//  换了语言 = 拿同一张图再跑一遍。
//

import Cocoa

@MainActor
final class OcrResultWindowController: NSObject {
    static let shared = OcrResultWindowController()

    private var window: NSWindow?
    private var textView: NSTextView?
    private var languagePopup: NSPopUpButton?
    private var layoutPopup: NSPopUpButton?
    private var statusLabel: NSTextField?
    private var copyButton: NSButton?

    /// 结果窗口的「底图」——换语言/排版时要用它重算。纯文本态（多图合并）为 nil。
    private var sourceImage: CGImage?
    private var sourceName = ""
    /// 每次识别递增，用来丢弃「早发出但晚返回」的旧结果。
    private var generation = 0

    private static let contentSize = NSSize(width: 572, height: 430)
    private static let barHeight: CGFloat = 36

    // MARK: - Show

    /// 对一张图取字。窗口立刻出现并显示「正在识别…」，识别完再填内容。
    /// near 传 nil 就落在鼠标所在的屏幕中央。
    func show(image: CGImage, sourceName: String, near screenFrame: NSRect?) {
        self.sourceImage = image
        self.sourceName = sourceName
        present(near: screenFrame)
        runRecognition()
    }

    /// 直接展示一段现成文本（多图合并用）。没有底图，所以重识别控件会被禁用。
    func show(text: String, sourceName: String, near screenFrame: NSRect?) {
        self.sourceImage = nil
        self.sourceName = sourceName
        present(near: screenFrame)
        statusLabel?.stringValue = "\(text.count)字"
        statusLabel?.textColor = .secondaryLabelColor
        textView?.string = text
        setReconfigureEnabled(false)
    }

    func close() {
        generation += 1
        window?.orderOut(nil)
        window = nil
        textView = nil
        languagePopup = nil
        layoutPopup = nil
        statusLabel = nil
        copyButton = nil
    }

    // MARK: - Window construction

    private func present(near screenFrame: NSRect?) {
        close()
        let size = Self.contentSize

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = sourceName.isEmpty ? "OCR 识别结果" : "OCR 识别结果 — \(sourceName)"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 420, height: 280)

        let content = NSView(frame: NSRect(origin: .zero, size: size))

        // 文本区（可编辑 + 可部分选中复制）
        let editorHeight = size.height - Self.barHeight
        let scroll = NSScrollView(frame: NSRect(x: 0, y: Self.barHeight,
                                                width: size.width, height: editorHeight))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = NSFont.systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.drawsBackground = true
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = editor
        content.addSubview(scroll)

        content.addSubview(buildBar(width: size.width))

        win.contentView = content
        win.setFrameOrigin(origin(for: win, near: screenFrame))
        window = win
        textView = editor
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(editor)
    }

    private func buildBar(width: CGFloat) -> NSView {
        let bar = NSStackView(frame: NSRect(x: 0, y: 0, width: width, height: Self.barHeight))
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        bar.autoresizingMask = [.width]

        let settings = AppSettings.shared

        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        language.addItems(withTitles: OcrLanguage.allCases.map(\.title))
        let stored = settings.ocrLanguage
        language.selectItem(at: OcrLanguage.allCases.firstIndex(of: stored) ?? 0)
        language.controlSize = .small
        language.font = NSFont.systemFont(ofSize: 11)
        language.target = self
        language.action = #selector(reconfigure)
        language.toolTip = "识别语言 —— 主语言选错会把另一种语言硬凑成近似字"
        languagePopup = language

        let layout = NSPopUpButton(frame: .zero, pullsDown: false)
        layout.addItems(withTitles: OcrLayout.allCases.map(\.title))
        layout.selectItem(at: OcrLayout.allCases.firstIndex(of: settings.ocrLayout) ?? 0)
        layout.controlSize = .small
        layout.font = NSFont.systemFont(ofSize: 11)
        layout.target = self
        layout.action = #selector(reconfigure)
        layout.toolTip = "按行保留原排版，或按行间距合并成段"
        layoutPopup = layout

        let autoCopy = NSButton(checkboxWithTitle: "识别后自动复制", target: self, action: #selector(toggleAutoCopy))
        autoCopy.state = settings.ocrAutoCopy ? .on : .off
        autoCopy.controlSize = .small
        autoCopy.font = NSFont.systemFont(ofSize: 11)

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel = status

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.font = NSFont.systemFont(ofSize: 11)
        copyButton = copy

        bar.addArrangedSubview(language)
        bar.addArrangedSubview(layout)
        bar.addArrangedSubview(autoCopy)
        bar.addArrangedSubview(status)
        bar.addArrangedSubview(copy)
        return bar
    }

    /// 落在截图附近（截图流程）或鼠标所在屏幕中央（快捷键/文件流程）。
    private func origin(for win: NSWindow, near screenFrame: NSRect?) -> NSPoint {
        let size = win.frame.size
        let screen: NSScreen?
        if let screenFrame, !screenFrame.isEmpty {
            screen = NSScreen.screens.first {
                $0.frame.contains(NSPoint(x: screenFrame.midX, y: screenFrame.midY))
            } ?? NSScreen.main
        } else {
            screen = ScreenUtils.screenContainingMouse() ?? NSScreen.main
        }
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let center = (screenFrame?.isEmpty == false)
            ? NSPoint(x: screenFrame!.midX, y: screenFrame!.midY)
            : NSPoint(x: visible.midX, y: visible.midY)
        let x = min(max(visible.minX + 8, center.x - size.width / 2), visible.maxX - size.width - 8)
        let y = min(max(visible.minY + 8, center.y - size.height / 2), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    // MARK: - Recognition

    private var selectedLanguage: OcrLanguage {
        let index = languagePopup?.indexOfSelectedItem ?? 0
        return OcrLanguage.allCases.indices.contains(index) ? OcrLanguage.allCases[index] : .zhEn
    }

    private var selectedLayout: OcrLayout {
        let index = layoutPopup?.indexOfSelectedItem ?? 0
        return OcrLayout.allCases.indices.contains(index) ? OcrLayout.allCases[index] : .lines
    }

    @objc private func reconfigure() { runRecognition() }

    private func runRecognition() {
        guard let image = sourceImage else { return }
        let language = selectedLanguage
        let layout = selectedLayout
        // 记住选择：下次截图/复制取字默认就用这套。
        AppSettings.shared.ocrLanguage = language
        AppSettings.shared.ocrLayout = layout

        generation += 1
        let token = generation
        setReconfigureEnabled(false)
        statusLabel?.stringValue = "正在识别…"

        Task { @MainActor in
            do {
                let outcome = try await OcrService.recognize(cgImage: image,
                                                            language: language,
                                                            layout: layout)
                guard token == self.generation else { return }   // 已被更新的请求取代
                self.apply(outcome)
            } catch {
                guard token == self.generation else { return }
                self.textView?.string = ""
                self.statusLabel?.stringValue = error.localizedDescription
                self.setReconfigureEnabled(true)
                self.copyButton?.isEnabled = false
            }
        }
    }

    private func apply(_ outcome: OcrOutcome) {
        textView?.string = outcome.text
        textView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
        copyButton?.isEnabled = true

        // 控制条上只放两三个数就够 —— 早先把行数/置信度都堆在状态里，
        // 结果尾巴被挤掉（"… · 置信 7…"）。完整数据放 tooltip。
        var parts = ["\(outcome.milliseconds)ms", "\(outcome.text.count)字"]
        let lowConfidence = outcome.confidence > 0 && outcome.confidence < 0.7
        if lowConfidence {
            parts.append("画面偏糊，可能不准")
        }
        if outcome.wasColdStart {
            parts.append("首次加载模型")
        }
        statusLabel?.stringValue = parts.joined(separator: " · ")
        statusLabel?.toolTip = """
        耗时 \(outcome.milliseconds) 毫秒 · \(outcome.lineCount) 行 · \(outcome.text.count) 字
        平均置信度 \(Int((outcome.confidence * 100).rounded()))%
        """
        // 置信度低说明画面可能太模糊，用颜色提示，别让人以为一定准。
        statusLabel?.textColor = lowConfidence ? .systemOrange : .secondaryLabelColor
        setReconfigureEnabled(true)

        if AppSettings.shared.ocrAutoCopy {
            copyToPasteboard(announce: true)
        }
    }

    private func setReconfigureEnabled(_ enabled: Bool) {
        languagePopup?.isEnabled = enabled
        layoutPopup?.isEnabled = enabled
    }

    // MARK: - Copy

    @objc private func toggleAutoCopy(_ sender: NSButton) {
        AppSettings.shared.ocrAutoCopy = (sender.state == .on)
    }

    @objc private func copyAll() { copyToPasteboard(announce: true) }

    private func copyToPasteboard(announce: Bool) {
        guard let text = textView?.string, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if announce { Toast.show("已复制到剪贴板") }
    }
}
