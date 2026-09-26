import Cocoa
import Carbon.HIToolbox
import Combine
import SwiftUI

/// 搜索面板的投影模式。
///
/// `soft`（默认）：**不用系统窗口阴影，改为玻璃层自绘**。原因是系统阴影按「窗口 frame」
/// 生成，而窗口是矩形 —— 阴影的四个角必然是**直角**，与圆角玻璃对不上（左下/右下角会
/// 尖出一个直角）。自绘阴影跟随玻璃的圆角形状，边缘与 UI 贴合。
/// 代价：自绘阴影要向外扩散，窗口必须留出透明留白（见 `outerPadding`），否则阴影被
/// 窗口边界裁掉。
///
/// ⚠️ 留白只有在**关掉系统窗口阴影**时才安全。系统阴影的最暗处永远落在窗口边缘，
/// 一旦留白又与玻璃错开，那条最暗线就会被晾在玻璃外侧成为多余的黑线（历史 bug）。
/// 两个条件必须同时满足：`hasShadow = false` + 有留白。
///
/// `system` 保留用于对照（旧观感：阴影直角）；`none` 用于排查。
///   defaults write com.waycast.macos WAYCAST_SHADOW_MODE -string system
enum PanelShadowMode: String {
    case soft, system, none

    static var current: PanelShadowMode {
        let raw = UserDefaults.standard.string(forKey: "WAYCAST_SHADOW_MODE") ?? "soft"
        return PanelShadowMode(rawValue: raw) ?? .soft
    }

    /// 是否使用系统窗口阴影（矩形、直角）。
    var usesWindowShadow: Bool { self == .system }

    /// 是否由玻璃层自绘圆角阴影。
    var drawsOwnShadow: Bool { self == .soft }

    /// 玻璃到窗口边缘的透明留白。自绘阴影需要空间向外扩散，否则会被窗口边界裁掉。
    /// `system` / `none` 下必须为 0，否则系统阴影最暗线会被晾出来（见上）。
    var outerPadding: CGFloat { self == .soft ? Self.shadowSpread : 0 }

    /// 自绘阴影向外扩散的半径（点）。窗口留白必须 ≥ 这个值。
    ///
    /// `blur(radius: 12)` 的可见扩散约 2.5–3 × 12 ≈ 30–36pt，所以取 44 留足余量。
    /// 留白不足时阴影尾部会被窗口边界硬裁 —— 视觉上就是面板下方一条明显的横线。
    /// 见 `PanelGlassBackground.ownShadow` 的实测表。
    static let shadowSpread: CGFloat = 44
}

/// Non-activating floating panel, centered on the screen under the cursor.
final class SpotlightPanel: NSPanel {
    init(contentRect: NSRect) {
        // 窗口用无边框。
        //
        // 为什么不用 `.titled`：titled 窗口会留出约 28pt 的 titlebar 区，SwiftUI
        // 把它当 safe area，内容被整体下推 —— 窗口顶部于是多出一段透明带，窗口
        // 边缘与玻璃边缘错开。后果有二：面板顶部凭空多出看不见的 28pt（点那里
        // 不会关闭面板），以及顶部阴影落到离玻璃 28pt 处（与底部黑线同源）。
        // 无边框时窗口边缘 = 玻璃边缘，投影四周均匀。
        //
        // 用 WAYCAST_PANEL_TITLED=1 可回退到旧样式做对比。
        let mask: NSWindow.StyleMask = UserDefaults.standard.bool(forKey: "WAYCAST_PANEL_TITLED")
            ? [.nonactivatingPanel, .titled, .fullSizeContentView]
            : [.nonactivatingPanel, .borderless]
        super.init(contentRect: contentRect,
                   styleMask: mask,
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        // Window dragging is handled manually by a gesture on the search bar
        // ONLY (see SearchPanelView): movableByWindowBackground would also
        // hijack file drags started inside the results list.
        isMovable = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        // 投影：默认改用玻璃层自绘的**圆角**阴影。系统窗口阴影是按「窗口 frame」生成的，
        // 而窗口是矩形 —— 阴影四角必然是直角，与圆角玻璃对不上。
        // 自绘阴影跟随玻璃圆角，但需要窗口留白供其扩散（见 PanelShadowMode.outerPadding）。
        // 两者是绑定的：关系统阴影 + 留白 必须同时成立，否则会退回「底边多余黑线」。
        hasShadow = PanelShadowMode.current.usesWindowShadow
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // ⌘W should not close the search panel (Esc is the exit); keeps the new
    // menu's performClose: from hiding it unexpectedly.
    override func performClose(_ sender: Any?) {}
}

/// Owns the search panel: toggling, keyboard navigation, actions.
@MainActor
final class SpotlightController: NSObject {
    private var panel: SpotlightPanel?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var clickMonitor: Any?
    private var globalClickMonitor: Any?
    private let viewModel = SearchViewModel()
    private var heightCancellable: AnyCancellable?
    private var moveCancellable: AnyCancellable?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// 开发者钩子专用：直接写入查询词并触发搜索，用来验证「展开结果」状态
    /// 下的面板 UI（配合 AppDelegate 的 WAYCAST_AUTO_QUERY）。
    func debugSetQuery(_ text: String) {
        viewModel.query = text
        viewModel.queryChanged()
    }

    func warmUp() {
        SearchEngine.shared.warmUp()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)

        let screen = ScreenUtils.screenContainingMouse()
        guard let screen else { return }
        let vf = screen.visibleFrame
        let width = SearchPanelLayout.width + SearchPanelLayout.padding * 2
        let collapsed = SearchPanelLayout.panelHeight(listHeight: 0)

        // Position: last dragged spot for THIS display if still on-screen,
        // else the default (horizontally centered, ~18% down from the top).
        //
        // `+ padding` 是给「玻璃层自绘阴影」留出的补偿：窗口比玻璃四周各大一圈
        // （SearchPanelLayout.padding），而定位锚的是窗口顶边 —— 不补偿的话玻璃会
        // 整体下沉一个 padding，面板看起来"位置变了"。加上后玻璃顶边回到原位。
        let key = AppSettings.displayKey(screen)
        var origin = NSPoint(x: vf.midX - width / 2,
                             y: vf.maxY - collapsed - vf.height * 0.18 + SearchPanelLayout.padding)
        if let saved = AppSettings.shared.searchPanelTopLeft(for: key) {
            // 记忆里存的是**玻璃**的左上角（见 watchMoves），而窗口比玻璃大一圈，
            // 所以要在 x 上往左、y 上往上各让出一个 padding 才能还原成窗口 origin。
            // 这样 padding 取值变化（不同投影模式）时，面板的视觉位置不会漂。
            let candidate = NSRect(origin: NSPoint(x: saved.x - SearchPanelLayout.padding,
                                                   y: saved.y + SearchPanelLayout.padding - collapsed),
                                   size: NSSize(width: width, height: collapsed))
            if vf.intersects(candidate) {
                origin = candidate.origin
            }
        }

        let panel: SpotlightPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = SpotlightPanel(contentRect: NSRect(origin: origin,
                                                       size: NSSize(width: width, height: collapsed)))
            let host = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
            host.frame = NSRect(x: 0, y: 0, width: width, height: collapsed)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            self.panel = panel
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: collapsed)), display: true)

        viewModel.onClose = { [weak self] in self?.hide() }
        panel.makeKeyAndOrderFront(nil)
        viewModel.reset(keepingQuery: true)
        // 上次的查询词还在（hide 不清空）—— 重新触发一次搜索把结果列表还原；
        // 词是空的就保持收起状态。
        if !viewModel.query.isEmpty { viewModel.queryChanged() }
        installKeyMonitor()
        installClickMonitors()
        observeHeight(width: width)
        watchMoves()
    }

    /// Persist the panel's top-left corner whenever the user drags it, keyed
    /// by the display the panel currently sits on (dragging to another screen
    /// stores it under that screen's own memory).
    private func watchMoves() {
        moveCancellable = NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel, let screen = panel.screen else { return }
                let key = AppSettings.displayKey(screen)
                // 存**玻璃**的左上角而不是窗口的：窗口四周多了一圈透明留白
                // （SearchPanelLayout.padding，给自绘阴影扩散用），存窗口角会让
                // 留白取值一变位置就偏。
                let topLeft = NSPoint(x: panel.frame.minX + SearchPanelLayout.padding,
                                      y: panel.frame.maxY - SearchPanelLayout.padding)
                AppSettings.shared.setSearchPanelTopLeft(topLeft, for: key)
            }
    }

    /// Clicking anywhere outside the panel dismisses it — exactly like
    /// Spotlight, whether or not there are results.
    private func installClickMonitors() {
        removeClickMonitors()
        let handle: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            // 判定用「玻璃」区域而不是窗口区域：窗口四周有一圈透明留白
            // （给自绘阴影扩散用），点在留白上应当算点击面板外部 —— 否则会在
            // 视觉上"面板外面"点一下却没关，像是失灵。
            let glass = panel.frame.insetBy(dx: SearchPanelLayout.padding,
                                            dy: SearchPanelLayout.padding)
            if glass.contains(NSEvent.mouseLocation) { return event }
            self.hide()
            return event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: handle)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { event in
            _ = handle(event)
        }
    }

    private func removeClickMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
    }

    /// Keep the panel's TOP edge anchored while the dropdown expands/collapses.
    /// The anchor is read from the CURRENT frame each time, so it keeps
    /// working after the user drags the panel somewhere else.
    private func observeHeight(width: CGFloat) {
        heightCancellable = viewModel.$listHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] listHeight in
                guard let self, let panel = self.panel else { return }
                let height = SearchPanelLayout.panelHeight(listHeight: listHeight)
                var frame = panel.frame
                guard abs(frame.size.height - height) > 0.5 else { return }
                let topY = frame.maxY
                frame.size = NSSize(width: width, height: height)
                frame.origin.y = topY - height
                // Clamp so the panel never leaves the visible screen area.
                if let vf = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                    if frame.minY < vf.minY { frame.origin.y = vf.minY }
                }
                panel.setFrame(frame, display: true, animate: false)
                (panel.contentView as? NSHostingView<SearchPanelView>)?.frame =
                    NSRect(x: 0, y: 0, width: width, height: height)
            }
    }

    func hide() {
        removeKeyMonitor()
        removeClickMonitors()
        heightCancellable = nil
        moveCancellable = nil
        panel?.orderOut(nil)
        // 保留 query：误触/误关后下次呼出不用重新输入（见 reset 的注释）。
        viewModel.reset(keepingQuery: true)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // While an IME composition is active (pinyin marked text on screen),
            // Return/arrows/Esc belong to the input method: Return commits the
            // typed letters, arrows move through candidates, Esc cancels the
            // composition. Intercepting them here is what made Return "do
            // nothing" in the search field with a Chinese IME.
            if self.isIMEComposing() { return event }
            switch event.keyCode {
            case UInt16(kVK_Escape):
                self.hide()
                return nil
            case UInt16(kVK_UpArrow):
                self.viewModel.moveSelection(by: -1)
                return nil
            case UInt16(kVK_DownArrow):
                self.viewModel.moveSelection(by: 1)
                return nil
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                self.viewModel.activateSelection()
                return nil
            default:
                return event
            }
        }
        // Fallback for Esc: as an accessory app with a non-activating panel,
        // the panel may not be key (e.g. after clicking another app), in which
        // case the local monitor never sees the event. A global monitor while
        // the panel is visible guarantees Esc always dismisses it.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor in self.hide() }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }

    /// True while an input-method composition is in flight (e.g. pinyin
    /// letters underlined in the search field). The field editor — an
    /// NSTextView — holds the marked text range.
    private func isIMEComposing() -> Bool {
        guard let panel else { return false }
        if let tv = panel.firstResponder as? NSTextView,
           tv.markedRange().location != NSNotFound { return true }
        return false
    }
}

enum ScreenUtils {
    static func screenContainingMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}
