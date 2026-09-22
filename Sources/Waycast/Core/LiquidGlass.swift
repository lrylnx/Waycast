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
