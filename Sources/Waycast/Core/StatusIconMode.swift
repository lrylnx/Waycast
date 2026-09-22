import Cocoa
import CoreText

/// 状态栏图标模式。状态栏只有一个位置，所以四种模式互斥 —— 同一时刻
/// 只有一个读数在画，其余 provider 的定时器全部销毁（关闭即零开销）。
enum StatusIconMode: String, CaseIterable {
    case bolt      // 默认闪电图标
    case memory    // 内存水位杯
    case network   // 实时网速
    case cpuTemp   // CPU 温度

    var menuTitle: String {
        switch self {
        case .bolt:    return "默认图标"
        case .memory:  return "内存水位图标"
        case .network: return "网速图标"
        case .cpuTemp: return "CPU 温度图标"
        }
    }

    /// 菜单里展示的实时读数后缀（菜单打开时才会刷新）。
    var readingLabel: String {
        switch self {
        case .bolt:    return ""
        case .memory:  return "内存"
        case .network: return "网速"
        case .cpuTemp: return "CPU"
        }
    }
}

// MARK: - 状态栏文字图标渲染

/// 状态栏里的文字型图标（网速、CPU 温度）。
///
/// 为什么不直接用 `NSStatusItem.title`：那样会和菜单的勾选项抢状态，也不好
/// 单独上色；这里统一走 `button.image`，和内存水位杯同一条路径。
enum StatusTextIcon {
    /// 状态栏字号与字重。
    ///
    /// **字体：必须用 `monospacedSystemFont`（SF Mono）而不能用
    /// `monospacedDigitSystemFont`。** 后者只让数字等宽，实测空格 3.27pt、
    /// 箭头 9.02pt、字母 M 10.09pt 各不相同，于是 "↓  0B ↑  0B"(67pt) 和
    /// "↓1.2M ↑340K"(81pt) 能差 14pt —— 图标每秒重绘一次，宽度一跳
    /// 右侧菜单栏里其它图标就跟着左右晃。SF Mono 实测每个字符（含 ↓ ↑
    /// 空格 字母 小数点）宽度完全一致，所以按固定字符数排版宽度就天然恒定。
    ///
    /// **字重：选 `.heavy`。** 实测 SF Mono 的字符宽度与字重无关
    /// （11pt 下 regular/medium/semibold/bold/heavy 都是 6.80pt），加粗不占位置。
    ///
    /// 为什么是 heavy 而不是 bold：把每种做法都渲染出来扫像素、算「墨迹覆盖率」
    /// （墨迹像素数 ÷ 墨迹包围盒面积，越大笔画越粗）实测：
    ///
    /// | 配置 | 覆盖率 | 图标尺寸 |
    /// |---|---|---|
    /// | 11pt bold（原） | 0.358 | 36×9pt |
    /// | **11pt heavy** | **0.438** | **36×9pt** |
    /// | 11.5pt bold | 0.360 | 38×9pt |
    /// | 12pt bold | 0.358 | 40×10pt |
    /// | 12pt heavy | 0.430 | 40×10pt |
    /// | 11pt bold + strokeWidth -1.2 | 0.398 | 36×9pt |
    ///
    /// 结论很反直觉：**加大字号几乎不增加笔画粗细**（12pt bold 还是 0.358，
    /// 只是整体放大），而且两行网速会从 20pt 涨到 22pt、正好顶满菜单栏。
    /// `.heavy` 才是把笔画真正加粗的那个（+22%），且尺寸分毫不变。
    /// （`.black` 实测与 `.heavy` 完全相同 —— SF Mono 没有更重的字重，会 fallback。）
    static func font() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: 11, weight: .heavy)
    }

    /// 单行内两层的行距（pt）。字面已经贴紧了，再留 2pt 免得两行糊在一起。
    private static let lineGap: CGFloat = 2

    /// 把一行或多行文字画成状态栏图标。
    ///
    /// 用 `"\n"` 分隔多行 —— 目前只有网速用两行（`↓1.2M` 一行、`↑340K` 一行）。
    ///
    /// **为什么多行要按「墨迹范围」裁着堆叠，而不是交给 `NSAttributedString` 排：**
    /// 菜单栏实测只有 22pt 高（`NSStatusBar.system.thickness`）。11pt 字体按
    /// **自然行距**排两行要 30pt，直接超框；而每行文字真实占的墨迹只有 8pt 高，
    /// 剩下的都是行高留白。所以这里逐行量出墨迹矩形，只按墨高堆叠、行间留 2pt，
    /// 两层合计 18pt，稳稳落在 22pt 里。
    ///
    /// - Parameter template: true 时交给系统按菜单栏明暗自动上色（并跟随点击高亮），
    ///   这是文字类图标最稳的做法；需要按数值报警上色时才传 false。
    static func render(_ text: String,
                       color: NSColor? = nil,
                       template: Bool,
                       scale: CGFloat = 2) -> NSImage {
        let textFont = font()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: color ?? .black,
            .kern: 0.0
        ]

        // 逐行量两样东西：排版宽度（advance，用来定图标宽度并对齐）和
        // 字形墨迹矩形（ink，用来做垂直定位）。
        //
        // **墨迹必须用 CoreText 的 `.useGlyphPathBounds` 量。** 一开始用的是
        // `NSAttributedString.boundingRect(with:options:)`，它返回的是整行
        // **行盒**（ascender + descender），11pt 下恒为 14pt —— 两层叠起来
        // 30pt，还是超菜单栏。`.useGlyphPathBounds` 拿的是字形轮廓的实际边界
        // （数字+箭头约 8pt 高），这才是"看得见的墨"。
        let lines = text.components(separatedBy: "\n")
        let measured: [(text: NSAttributedString, advance: CGFloat, ink: NSRect)] =
            lines.map { raw in
                let attributed = NSAttributedString(string: raw, attributes: attrs)
                var ink = CTLineGetBoundsWithOptions(
                    CTLineCreateWithAttributedString(attributed),
                    [.useGlyphPathBounds])
                // CTLine 的原点在**基线左端**，而 `draw(at:)` 的原点在**行盒左下角**，
                // 两者差一个 descender 的高度，这里换算到同一个坐标系。
                ink.origin.y += -textFont.descender
                return (attributed, attributed.size().width, ink)
            }

        // 宽度仍按**排版宽度**取最大值，这样单行图标的宽度和加多行之前分毫不差
        // （SF Mono 等宽 → 固定字符数 = 固定宽度 → 图标不会每秒抖）。
        let contentWidth = measured.map(\.advance).max() ?? 0
        let widthPt = ceil(contentWidth) + 2        // 左右各留 1pt，避免贴住邻居

        // 高度按墨迹累加：两行 = 8 + 2 + 8 = 18pt；单行 = 8pt。
        let inkHeights = measured.map { max(ceil($0.ink.height), 1) }
        let gapTotal = lineGap * CGFloat(max(measured.count - 1, 0))
        let heightPt = inkHeights.reduce(0, +) + gapTotal

        let pixelW = Int(ceil(widthPt * scale))
        let pixelH = Int(ceil(heightPt * scale))

        guard pixelW > 0, pixelH > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelW, pixelsHigh: pixelH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: max(widthPt, 1), height: max(heightPt, 1)))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        // 透明底上关掉次像素抗锯齿，否则会出现彩边。
        ctx.cgContext.setShouldSmoothFonts(false)
        // 裁掉留白后字形贴得近，打开普通抗锯齿让边缘过渡自然一点。
        ctx.cgContext.setShouldAntialias(true)

        // 自顶向下逐行堆叠。注意 `ink.origin` 是墨迹相对**绘制原点**的偏移，
        // 必须把它减掉才能让墨迹边（而不是排版行盒）落在目标位置 —— 否则每行
        // 会整体偏下约 1.5~2pt，两层叠起来就歪了。
        //
        // 水平对齐分两种，别混：
        // - **单行**（CPU 温度）按**墨迹**居中。温度是定宽 5 字符，位数不同时
        //   前面补空格（"  8°C" / " 42°C" / "105°C"），若按 advance 对齐，
        //   墨迹会随数字位数在图标里左右滑动（实测 " 42°C" 时右边只剩 1pt、
        //   左边空 7.8pt，看起来明显偏右）。按墨迹居中后左右留白恒定相等。
        // - **多行**（网速）按 **advance** 对齐，让两行的字符格子起点重合；
        //   否则 "↑340K" 和 "↓ 12K"（一个带前导空格）的箭头会左右错位。
        let inkCentered = measured.count == 1
        var cursorTop = heightPt                    // 当前行的墨迹顶边
        for (index, m) in measured.enumerated() {
            let inkBottom = cursorTop - inkHeights[index]
            let x = inkCentered
                ? (widthPt - m.ink.width) / 2 - m.ink.origin.x
                : 1 + (contentWidth - m.advance) / 2 - m.ink.origin.x
            let y = inkBottom - m.ink.origin.y
            m.text.draw(at: NSPoint(x: x, y: y))
            cursorTop = inkBottom - lineGap
        }

        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: widthPt, height: heightPt)
        let image = NSImage(size: NSSize(width: widthPt, height: heightPt))
        image.addRepresentation(rep)
        image.isTemplate = template
        return image
    }

    /// 当前界面明暗下"系统文字色"的实际取值。
    ///
    /// 只在需要给数值上色（非 template）时用得到；每秒重绘一次，所以即使
    /// 系统切换明暗主题时取到了旧值，下一个 tick 也会自动纠正。
    static func resolvedLabelColor() -> NSColor {
        var resolved = NSColor.labelColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
        }
        return resolved
    }
}
