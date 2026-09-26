//
//  OcrService.swift
//  Waycast
//
//  文字识别引擎：Apple Vision，离线、免费、不联网、不需要任何密钥。
//
//  三个曾经踩过的坑（都在这里修掉）：
//
//  1. Vision 的模型是**按语言加载**的：首次调用要十几秒，之后同语言只要几十毫秒。
//     → 启动时后台 warmUp()，把这份开销提前吃掉；换语言后重新预热。
//  2. `.fast` 识别级别**不支持中文**（输出乱码），所以固定 `.accurate`。
//  3. 识别结果只有「按行」一种排列时，长段落复制出去换行是乱的。
//     → 用 boundingBox 的行间距中位数判断段落边界，提供「合并成段」。
//

import Cocoa
import Vision

// MARK: - Language

/// 识别语言。数组顺序即 Vision 的优先级：**第一个是主语言**，
/// 主语言选错会把另一种语言的字符「硬凑」成本语言的近似字。
enum OcrLanguage: String, CaseIterable, Codable {
    case zhEn
    case zhHans
    case zhHant
    case en
    case ja
    case ko

    var title: String {
        switch self {
        case .zhEn:   return "中英混排（推荐）"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁体中文"
        case .en:     return "英文"
        case .ja:     return "日文"
        case .ko:     return "韩文"
        }
    }

    /// 语言代码 + 该语言下要关闭语言纠正的标记。
    var visionLanguages: [String] {
        switch self {
        case .zhEn:   return ["zh-Hans", "en-US"]
        case .zhHans: return ["zh-Hans"]
        case .zhHant: return ["zh-Hant"]
        case .en:     return ["en-US"]
        case .ja:     return ["ja-JP"]
        case .ko:     return ["ko-KR"]
        }
    }

    /// 预热用的缓存键，也是去重依据。
    var cacheKey: String { visionLanguages.joined(separator: "+") }
}

// MARK: - Layout

enum OcrLayout: String, CaseIterable, Codable {
    /// 保留识别到的原始分行，适合表格、代码、清单。
    case lines
    /// 按行间距把同一段的行接起来，适合正文、聊天记录。
    case paragraph

    var title: String {
        switch self {
        case .lines:     return "按行（保留排版）"
        case .paragraph: return "合并成段"
        }
    }
}

// MARK: - Outcome

struct OcrOutcome {
    /// 最终文本（已按 layout 处理）。
    var text: String
    /// 识别到的原始行数（不受 layout 影响）。
    var lineCount: Int
    /// 本次识别耗时（毫秒）。首次识别会包含模型加载，之后是纯识别耗时。
    var milliseconds: Int
    /// 平均置信度 0…1，用来判断「是不是识别得不靠谱」。
    var confidence: Double
    /// 该次识别是否触发了模型加载（UI 上可以据此解释「为什么这次慢」）。
    var wasColdStart: Bool
}

enum OcrError: LocalizedError {
    case emptyResult
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyResult:      return "未识别到文字"
        case .failed(let why):  return why
        }
    }
}

// MARK: - Service

/// 全局唯一的 OCR 引擎。所有识别都排在同一条串行队列上 ——
/// Vision 的请求对象不是线程安全的，且并发跑同一语言反而更慢。
enum OcrService {
    private static let queue = DispatchQueue(label: "com.waycast.ocr", qos: .userInitiated)
    /// 已经预热过的语言集合（cacheKey）。
    private static var warmedLanguages = Set<String>()
    /// 1×1 的占位图，仅用于驱动一次完整请求以加载模型。
    private static let probeImage: CGImage? = {
        let ctx = CGContext(data: nil, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }()

    // MARK: Request

    private static func makeRequest(language: OcrLanguage) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        // .fast 不支持中文，会输出乱码 —— 永远用 .accurate。
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        var languages = language.visionLanguages
        if let supported = try? request.supportedRecognitionLanguages() {
            let filtered = languages.filter { supported.contains($0) }
            // 一个都不支持时别硬塞：交给 Vision 用默认语言，总比报错强。
            if !filtered.isEmpty { languages = filtered }
        }
        request.recognitionLanguages = languages
        // 不手动锁 revision：跟系统默认（当前最新）走，语言支持面最宽。
        return request
    }

    // MARK: Warm-up

    /// 预热：把指定语言的 Vision 模型提前加载进内存。
    /// 实测首次加载约 15 秒，之后同一语言稳定在 ~60ms —— 不预热的话，
    /// 用户第一次点「提取文字」就要对着空白等十几秒。
    static func warmUp(language: OcrLanguage, completion: (() -> Void)? = nil) {
        queue.async {
            if isWarmed(language) {
                DispatchQueue.main.async { completion?() }
                return
            }
            let started = Date()
            if let probe = probeImage {
                let request = makeRequest(language: language)
                let handler = VNImageRequestHandler(cgImage: probe, orientation: .up, options: [:])
                try? handler.perform([request])
            }
            markWarmed(language)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            NSLog("[Waycast] OCR 模型预热完成（%@），耗时 %d ms", language.rawValue, ms)
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: Recognize

    static func recognize(cgImage: CGImage,
                          language: OcrLanguage,
                          layout: OcrLayout = .lines) async throws -> OcrOutcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let wasCold = !isWarmed(language)
                let started = Date()

                let request = makeRequest(language: language)
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    NSLog("[Waycast] OCR 失败: %@", "\(error)")
                    continuation.resume(throwing: OcrError.failed(error.localizedDescription))
                    return
                }
                markWarmed(language)

                // 每条 observation 取最佳候选，同时保留它的框（段落判断要用）。
                let recognized: [(text: String, box: CGRect, confidence: Float)] =
                    (request.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return (candidate.string, observation.boundingBox, candidate.confidence)
                    }

                let milliseconds = Int(Date().timeIntervalSince(started) * 1000)

                guard !recognized.isEmpty else {
                    continuation.resume(throwing: OcrError.emptyResult)
                    return
                }

                let average = Double(recognized.reduce(0) { $0 + $1.confidence }) / Double(recognized.count)

                let text: String
                switch layout {
                case .lines:
                    text = recognized.map(\.text).joined(separator: "\n")
                case .paragraph:
                    text = paragraphs(recognized)
                }

                continuation.resume(returning: OcrOutcome(text: text,
                                                          lineCount: recognized.count,
                                                          milliseconds: milliseconds,
                                                          confidence: average,
                                                          wasColdStart: wasCold))
            }
        }
    }

    // MARK: Paragraph merging

    /// 用行间距判断段落边界：相邻两行的垂直间隙明显大于「中位行距」时，
    /// 认为换了一段。比「看有没有句号」稳 —— 中文截图里经常整段没标点。
    private static func paragraphs(_ recognized: [(text: String, box: CGRect, confidence: Float)]) -> String {
        guard recognized.count > 1 else { return recognized.first?.text ?? "" }

        // Vision 的 boundingBox 是归一化坐标且原点在左下：y 越大越靠上。
        var gaps: [CGFloat] = []
        for index in 1..<recognized.count {
            let upper = recognized[index - 1].box
            let lower = recognized[index].box
            gaps.append(max(0, upper.minY - lower.maxY))
        }

        let sortedGaps = gaps.sorted()
        // 基准取**下四分位**而不是中位数：段内行距总归是最小的那一批 gap，
        // 而段落之间的空行会把中位数抬上去 —— 取中位数会把段间距也算成
        // 「正常行距」，于是段落全被粘在一起（实测踩过：标题被并进正文）。
        let baseline = sortedGaps[max(0, (sortedGaps.count - 1) / 4)]
        let threshold = max(baseline * 1.6, 0.003)

        var result = recognized[0].text
        for index in 1..<recognized.count {
            let gap = gaps[index - 1]
            // 上一行以句末标点收尾，也是换段的强信号。
            let previousEndsSentence = recognized[index - 1].text
                .trimmingCharacters(in: .whitespaces)
                .last
                .map { "。！？…；.!?;".contains($0) } ?? false
            if gap > threshold || previousEndsSentence {
                result += "\n" + recognized[index].text
            } else {
                // 同一段内接行：英文断词换行原本带空格，接回去要补一个，
                // 否则 "…amount" + "Hello" 会粘成 "amountHello"。中文之间不补。
                result += joiningSeparator(result, recognized[index].text) + recognized[index].text
            }
        }
        return result
    }

    /// 段落内接行时的分隔符。
    /// 只要接缝的任一侧是 ASCII 字母/数字就补一个空格 —— 中文排版里中英之间
    /// 留白更易读（"amount ¥1,234.56工号" → "amount ¥1,234.56 工号"）。
    /// 两侧都是中文时不补，免得多出空格。
    private static func joiningSeparator(_ head: String, _ tail: String) -> String {
        func isASCIIAlphanumeric(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }
        guard let last = head.last, let first = tail.first,
              !last.isWhitespace, !first.isWhitespace else { return "" }
        guard isASCIIAlphanumeric(last) || isASCIIAlphanumeric(first) else { return "" }
        return " "
    }

    // MARK: Warm cache bookkeeping

    private static func isWarmed(_ language: OcrLanguage) -> Bool {
        warmedLanguages.contains(language.cacheKey)
    }

    private static func markWarmed(_ language: OcrLanguage) {
        warmedLanguages.insert(language.cacheKey)
    }
}
