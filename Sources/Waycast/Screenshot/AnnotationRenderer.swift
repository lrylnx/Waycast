import Cocoa

/// Renders annotations into a CGContext. Assumes a FLIPPED coordinate space
/// (top-left origin, y increasing downward) — the same space as the overlay
/// view and the compositor.
enum AnnotationRenderer {
    struct Context {
        let desktop: CGImage        // full captured desktop image (pixels)
        let pixelated: CGImage?     // cached pixelated variant for mosaic
        let viewSize: CGSize        // size of the desktop in view points
    }

    static func draw(_ a: Annotation, ctx: CGContext, rc: Context) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .rect where a.points.count >= 2:
            let r = CGRect(points: [a.points[0], a.points[1]])
            let radius = min(r.width, r.height) / 2 * 0.5   // gentle rounded corners
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokePath()
        case .pen where a.points.count >= 2:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.addLines(between: a.points)
            ctx.strokePath()
        case .arrow where a.points.count >= 2:
            drawArrow(a, ctx: ctx)
        case .mosaic:
            drawMosaic(a, ctx: ctx, rc: rc)
        case .text:
            drawText(a, ctx: ctx)
        default:
            break
        }
        ctx.restoreGState()
    }

    /// Vector-based arrowhead (ported from SnapPin): works identically in the
    /// flipped (y-down) space, with a length guard so a click without drag
    /// doesn't render a degenerate reversed head.
    private static func drawArrow(_ a: Annotation, ctx: CGContext) {
        guard let p1 = a.points.first, let p2 = a.points.last else { return }
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1 else { return }
        let headLen = max(12, a.lineWidth * 3.5)
        let half = headLen * 0.38
        let ux = dx / len, uy = dy / len
        let back = CGPoint(x: p2.x - ux * headLen, y: p2.y - uy * headLen)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.move(to: p1)
        ctx.addLine(to: CGPoint(x: back.x - ux * 2, y: back.y - uy * 2))
        ctx.strokePath()
        let perp = CGPoint(x: -uy, y: ux)
        ctx.move(to: p2)
        ctx.addLine(to: CGPoint(x: back.x + perp.x * half, y: back.y + perp.y * half))
        ctx.addLine(to: CGPoint(x: back.x - perp.x * half, y: back.y - perp.y * half))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawMosaic(_ a: Annotation, ctx: CGContext, rc: Context) {
        guard let pix = rc.pixelated else { return }
        ctx.setLineWidth(max(20, a.lineWidth * 6))
        if a.points.count > 1 {
            let path = CGMutablePath()
            path.addLines(between: a.points)
            ctx.addPath(path)
            ctx.replacePathWithStrokedPath()
        } else if let p = a.points.first {
            ctx.addEllipse(in: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30))
        }
        ctx.clip()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSImage(cgImage: pix, size: rc.viewSize).draw(in: CGRect(origin: .zero, size: rc.viewSize))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ a: Annotation, ctx: CGContext) {
        guard let p = a.points.first, !a.text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold),
            .foregroundColor: a.color
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (a.text as NSString).draw(at: p, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
