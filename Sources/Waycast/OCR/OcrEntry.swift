//
//  OcrEntry.swift
//  Waycast
//
//  OCR 的入口层：把「图从哪来」和「识别怎么跑」分开。
//
//  三条来源：
//    · 截图（截图工具栏的「OCR 文字识别」按钮，见 CaptureController）
//    · 剪贴板里的图片（全局快捷键，**不需要屏幕录制权限**，也最快）
//    · 磁盘上的图片文件（可多选）
//
//  识别本身一律交给 OcrService；窗口只负责显示与重识别，见 OcrResultWindow。
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum OcrEntry {

    // MARK: - 剪贴板

    /// 读剪贴板里的图片。按位图类型优先读原始数据 —— 直接要 NSImage 会被
    /// 系统做一次色彩/缩放转换，小字容易糊。
    static func clipboardImage() -> CGImage? {
        let pasteboard = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        // 兜底：截图 App 塞进来的可能是别的位图类，或 NSImage 才能解码的格式。
        if let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil),
           let image = objects.first as? NSImage {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    /// 快捷键入口：对剪贴板里的图片取字。
    static func recognizeClipboard() {
        guard let image = clipboardImage() else {
            Toast.show("剪贴板里没有图片 —— 先截图或复制一张图")
            return
        }
        OcrResultWindowController.shared.show(image: image,
                                             sourceName: "剪贴板图片",
                                             near: nil)
    }

    // MARK: - 图片文件

    static func recognizeImageFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要取字的图片"
        panel.prompt = "取字"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP, .pdf]
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                if urls.count == 1, let url = urls.first {
                    guard let image = loadImage(at: url) else {
                        Toast.show("这个文件读不出图片")
                        return
                    }
                    OcrResultWindowController.shared.show(image: image,
                                                         sourceName: url.lastPathComponent,
                                                         near: nil)
                } else {
                    await recognizeMany(urls)
                }
            }
        }
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 多选：逐张识别再拼成一份结果。多张图没法共用「重识别」那个开关，
    /// 所以走纯文本窗口。
    private static func recognizeMany(_ urls: [URL]) async {
        let language = AppSettings.shared.ocrLanguage
        let layout = AppSettings.shared.ocrLayout
        Toast.show("正在识别 \(urls.count) 张图片…", duration: 2.0)

        var sections: [String] = []
        var failures: [String] = []
        for url in urls {
            guard let image = loadImage(at: url) else {
                failures.append("\(url.lastPathComponent)（读不出图片）")
                continue
            }
            do {
                let outcome = try await OcrService.recognize(cgImage: image,
                                                            language: language,
                                                            layout: layout)
                sections.append("──── \(url.lastPathComponent) ────\n\(outcome.text)")
            } catch {
                failures.append("\(url.lastPathComponent)（\(error.localizedDescription)）")
            }
        }

        guard !sections.isEmpty else {
            Toast.show(failures.first ?? "都没识别到文字", duration: 2.6)
            return
        }
        var text = sections.joined(separator: "\n\n")
        if !failures.isEmpty {
            text += "\n\n（未识别出文字：\(failures.joined(separator: "、"))）"
        }
        OcrResultWindowController.shared.show(text: text,
                                             sourceName: "\(sections.count) 张图片",
                                             near: nil)
    }

    // MARK: - 开发者钩子（自动化验证用）

    /// 对指定路径的图片跑一次 OCR 并把过程写进一个文本文件，不弹任何界面。
    /// 由 AppDelegate 的 `WAYCAST_OCR_FILE` 钩子驱动 —— 这样验证识别链路
    /// 不需要人点界面，也不需要屏幕录制权限。
    ///
    /// 结果写成文件而不是只打日志：GUI 进程的 NSLog 走统一日志、不进 stderr，
    /// 从命令行重定向抓不到。文件里每一步都落盘，卡在哪一步也看得见。
    static func debugRecognizeFile(_ path: String, exitWhenDone: Bool) {
        let outputPath = UserDefaults.standard.string(forKey: "WAYCAST_OCR_OUT")
            ?? "/tmp/waycast_ocr_result.txt"

        Task { @MainActor in
            var report = "step=start at=\(Date())\nimage=\(path)\n"
            func flush() {
                try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
            }
            flush()

            guard let image = loadImage(at: URL(fileURLWithPath: path)) else {
                report += "step=load-image FAILED\n"
                flush()
                if exitWhenDone { exit(2) }
                return
            }
            report += "step=load-image ok size=\(image.width)x\(image.height)\n"
            flush()

            // 只验证窗口形态时走这条：直接弹结果窗口，不写报告也不退出。
            //   defaults write com.waycast.macos WAYCAST_OCR_SHOW_WINDOW -bool true
            if UserDefaults.standard.bool(forKey: "WAYCAST_OCR_SHOW_WINDOW") {
                OcrResultWindowController.shared.show(
                    image: image,
                    sourceName: URL(fileURLWithPath: path).lastPathComponent,
                    near: nil)
                return
            }

            let defaults = UserDefaults.standard
            let language = defaults.string(forKey: "WAYCAST_OCR_LANG")
                .flatMap(OcrLanguage.init(rawValue:)) ?? AppSettings.shared.ocrLanguage
            let layout = defaults.string(forKey: "WAYCAST_OCR_LAYOUT")
                .flatMap(OcrLayout.init(rawValue:)) ?? AppSettings.shared.ocrLayout
            report += "step=start-ocr language=\(language.rawValue) layout=\(layout.rawValue)\n"
            flush()

            do {
                // 跑两次：第一次可能还在加载模型（冷），第二次必然已预热 ——
                // 两次的差值就是「预热到底有没有用」的证据。
                let first = try await OcrService.recognize(cgImage: image,
                                                          language: language,
                                                          layout: layout)
                report += "step=first-done ms=\(first.milliseconds) cold=\(first.wasColdStart ? 1 : 0) lines=\(first.lineCount) chars=\(first.text.count) confidence=\(String(format: "%.3f", first.confidence))\n"
                flush()

                let second = try await OcrService.recognize(cgImage: image,
                                                           language: language,
                                                           layout: layout)
                report += "step=second-done ms=\(second.milliseconds) cold=\(second.wasColdStart ? 1 : 0)\n"
                report += "----TEXT-BEGIN----\n\(first.text)\n----TEXT-END----\n"
                flush()
                if exitWhenDone { exit(0) }
            } catch {
                report += "step=ocr FAILED \(error.localizedDescription)\n"
                flush()
                if exitWhenDone { exit(3) }
            }
        }
    }
}
