import Cocoa
import Combine

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, rect, pen, text, arrow, mosaic
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "hand"          // pan/move
        case .rect: return "rectangle"
        case .pen: return "pencil.line"
        case .text: return "textformat"      // unused; rendered as letter "T"
        case .arrow: return "arrow.up.right"
        case .mosaic: return "mosaic"
        }
    }

    /// Some tools read better as a plain glyph than an SF Symbol
    /// (character.cursor.ibeam looked like "AI").
    var letter: String? {
        self == .text ? "T" : nil
    }

    var label: String {
        switch self {
        case .select: return "选择"
        case .rect: return "矩形"
        case .pen: return "画笔"
        case .text: return "文字"
        case .arrow: return "箭头"
        case .mosaic: return "马赛克"
        }
    }
}

final class Annotation: ObservableObject, Identifiable {
    enum Kind { case rect, pen, text, arrow, mosaic }
    let id = UUID()
    let kind: Kind
    @Published var points: [CGPoint]      // flipped view coords; rect: [origin, corner]; text: [origin]
    @Published var color: NSColor
    @Published var lineWidth: CGFloat
    @Published var text: String
    @Published var fontSize: CGFloat

    init(kind: Kind, points: [CGPoint], color: NSColor, lineWidth: CGFloat,
         text: String = "", fontSize: CGFloat = 18) {
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
    }

    var boundingRect: CGRect {
        switch kind {
        case .rect:
            guard points.count >= 2 else { return .zero }
            return CGRect(points: [points[0], points[1]])
        case .mosaic:
            guard !points.isEmpty else { return .zero }
            let r: CGFloat = lineWidth * 4
            return CGRect(points: points).insetBy(dx: -r, dy: -r)
        case .pen, .arrow:
            guard !points.isEmpty else { return .zero }
            let r = lineWidth
            return CGRect(points: points).insetBy(dx: -r, dy: -r)
        case .text:
            guard let p = points.first else { return .zero }
            let w = max(40, (text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize)]).width)
            return CGRect(x: p.x, y: p.y, width: w, height: fontSize * 1.35)
        }
    }
}

extension CGRect {
    init(points: [CGPoint]) {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        if minX > maxX { self = .zero } else { self = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
    }
}

/// Shared state for one screenshot session.
final class ScreenshotModel: ObservableObject {
    @Published var tool: AnnotationTool = .select
    @Published var lineWidth: CGFloat = 5
    @Published var fontSize: CGFloat = 18
    @Published var color: NSColor = .systemRed
    @Published var annotations: [Annotation] = []
    @Published var selection: CGRect = .zero     // view (flipped, top-left origin) coords
    @Published var hasSelection: Bool = false
    @Published var isDrawing: Bool = false
    @Published var ocrText: String? = nil
    @Published var ocrRunning: Bool = false

    let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                              .systemGreen, .systemBlue, .systemPurple, .black, .white]

    // Full-desktop captured image + geometry (set by the controller).
    var desktopImage: CGImage?
    var desktopScale: CGFloat = 2
    weak var overlayView: ScreenshotOverlayView?

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        overlayView?.needsDisplay = true
    }

    func adjustSize(by delta: CGFloat) {
        switch tool {
        case .rect, .pen, .arrow, .mosaic:
            lineWidth = max(1, min(40, lineWidth + delta))
        case .text:
            fontSize = max(10, min(72, fontSize + delta * 2))
        case .select:
            break
        }
    }

    func currentSizeValue() -> CGFloat {
        tool == .text ? fontSize : lineWidth
    }
}
