//
//  LiquidGlass.swift
//  Waycast
//
//  macOS 26 起 AppKit 提供了原生液态玻璃容器 NSGlassEffectView（27 起还支持
//  effectIsInteractive：按下去有回弹反馈）。这个工具把「给一块浮动工具条套上
//  玻璃底」这件事收敛成一处：
//
//  - macOS 26+ → NSGlassEffectView（真·液态玻璃：实时折射+高光+自适应当前外观）
//  - 旧系统     → 半透明色块 + 1px 高光描边 + 投影，观感接近但不折射
//
//  用法：`GlassBackdrop.wrap(stack, cornerRadius: 12)` —— 返回的容器尺寸就是
//  content 的 fittingSize，直接拿来定位/计算展示位置即可。
//

import AppKit

@MainActor
enum GlassBackdrop {

    /// 当前系统是否支持原生液态玻璃（macOS 26+）。
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 把 `content` 装进带玻璃底的容器，返回该容器。
    ///
    /// - Parameters:
    ///   - content: 工具条内容（通常是一个 NSStackView），尺寸取它的 fittingSize。
    ///   - cornerRadius: 玻璃圆角。macOS 26 的玻璃用连续圆角，12 左右观感最佳。
    ///   - fallbackBackground: 旧系统（< 26）用的底色。
    ///   - interactive: 是否要交互反馈（按压回弹）。仅 macOS 27+ 生效。
    static func wrap(_ content: NSView,
                     cornerRadius: CGFloat = 12,
                     fallbackBackground: NSColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96),
                     interactive: Bool = true) -> NSView {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let frame = NSRect(origin: .zero, size: size)
        content.frame = frame

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.frame = frame
            glass.contentView = content
            if #available(macOS 27.0, *) {
                // 工具条整条都是按钮，开交互反馈后按下有玻璃回弹。
                glass.effectIsInteractive = interactive
            }
            applyDropShadow(to: glass, opacity: 0.30, radius: 12, offset: -4)
            return glass
        }

        let box = NSView(frame: frame)
        box.wantsLayer = true
        box.layer?.backgroundColor = fallbackBackground.cgColor
        box.layer?.cornerRadius = cornerRadius
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        box.addSubview(content)
        content.frame = frame
        applyDropShadow(to: box, opacity: 0.35, radius: 9, offset: -3)
        return box
    }

    /// 让玻璃工具条从截图上「浮起来」。阴影画在容器自身的 layer 上，
    /// 不参与玻璃的折射计算。
    private static func applyDropShadow(to view: NSView, opacity: Float, radius: CGFloat, offset: CGFloat) {
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = opacity
        view.layer?.shadowRadius = radius
        view.layer?.shadowOffset = NSSize(width: 0, height: offset)
    }
}

// MARK: - SwiftUI 侧

#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI 版的液态玻璃面板底。
///
/// AppKit 侧用 `GlassBackdrop.wrap(_:cornerRadius:)`（自己建 NSGlassEffectView 当容器）；
/// SwiftUI 侧则用系统给的 `.glassEffect(_:in:)` modifier —— 底层同样是
/// NSGlassEffectView，但它能正常参与 SwiftUI 的布局、动画与圆角裁剪，
/// 不需要套一层 NSViewRepresentable（那样要么尺寸对不上，要么状态被隔离）。
///
/// 玻璃采样的是**面板背后的内容**。搜索面板本身是 `isOpaque = false` 的
/// 透明 NSPanel，所以能透出并折射它下面的桌面 / 其他窗口 —— 正是要的效果。
///
/// 变体用 `WAYCAST_GLASS_VARIANT` 切换，默认 `regular`（定稿值）：
///   defaults write com.waycast.macos WAYCAST_GLASS_VARIANT -string clear
struct PanelGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 18

    /// regular = 系统默认（强模糊+提亮，可读性最好）—— **定稿值**
    /// clear   = 通透（几乎不模糊，背后文字会与列表文字混叠，可读性受损）
    /// mix     = clear 玻璃 + ultraThinMaterial 垫层
    ///
    /// 实测结论：`regular` 观感与可读性最好（2026-09-23 真机 A/B）。
    /// 另外两种只作为 `WAYCAST_GLASS_VARIANT` 的调试选项保留。
    private var variant: String {
        UserDefaults.standard.string(forKey: "WAYCAST_GLASS_VARIANT") ?? "regular"
    }

    func body(content: Content) -> some View {
        if PanelShadowMode.current.drawsOwnShadow {
            glassLayer(content)
                .background { ownShadow }
        } else {
            glassLayer(content)
        }
    }

    @ViewBuilder
    private func glassLayer(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            switch variant {
            case "clear":
                content.glassEffect(.clear, in: shape)
            case "mix":
                // clear 玻璃 + ultraThinMaterial 垫层
                content
                    .background(shape.fill(.ultraThinMaterial))
                    .glassEffect(.clear, in: shape)
            default:
                content.glassEffect(.regular, in: shape)
            }
        } else {
            // 旧系统没有 NSGlassEffectView，退回毛玻璃材质 + 高光描边。
            content
                .background(shape.fill(.ultraThinMaterial))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// 自绘圆角阴影。
    ///
    /// 系统窗口阴影（`hasShadow = true`）是按「窗口 frame」生成的，而窗口是矩形 ——
    /// 阴影四角必然是**直角**，在圆角玻璃的下方会尖出两个角，与 UI 不贴合。
    /// 这里改成自己画：基准形状取**和玻璃完全相同的圆角矩形**，再用 `blur` 向外柔化扩散，
    /// 于是阴影的轮廓与玻璃圆角一致。画在玻璃**后面**（`.background`）。
    ///
    /// 对外扩散的距离由 `PanelShadowMode.shadowSpread` 描述，窗口留白必须 ≥ 它，
    /// 否则阴影会被窗口边界**硬裁**成一条明显的横线（阴影还没衰减完就断了）。
    ///
    /// 实测（2026-09-23，纯白背景 + 逐行亮度剖面）：
    ///
    /// | 留白 | blur | 阴影跨度 | 窗口边界前 3px 的亮度跳变 |
    /// |---|---|---|---|
    /// | 22pt | 9 | 22pt | **+0.038 → 可见硬边** |
    /// | 38pt | 9 | 35.5pt | +0.004 → 平缓 |
    /// | 44pt | 12 | 36pt | +0.004 → 平缓（定稿） |
    ///
    /// 结论：`blur(radius: r)` 的可见扩散约 **2.5–3 × r**，留白必须 ≥ 这个值。
    /// 定稿 44pt 留白配 `r = 12`，四周（含顶部与左右）都留够了余量。
    private var ownShadow: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.40))
            .blur(radius: 12)
            .offset(y: 7)
    }
}

extension View {
    /// 给面板套上 macOS 26 的液态玻璃底；旧系统自动退回毛玻璃材质。
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        modifier(PanelGlassBackground(cornerRadius: cornerRadius))
    }
}
#endif
