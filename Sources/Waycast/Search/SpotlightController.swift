import Cocoa
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Non-activating floating panel, centered on the screen under the cursor.
final class SpotlightPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
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
        hasShadow = true
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
        let key = AppSettings.displayKey(screen)
        var origin = NSPoint(x: vf.midX - width / 2,
                             y: vf.maxY - collapsed - vf.height * 0.18)
        if let saved = AppSettings.shared.searchPanelTopLeft(for: key) {
            let candidate = NSRect(origin: NSPoint(x: saved.x, y: saved.y - collapsed),
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
        viewModel.reset()
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
                let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
                AppSettings.shared.setSearchPanelTopLeft(topLeft, for: key)
            }
    }

    /// Once results exist, clicking anywhere outside the panel dismisses it
    /// (Spotlight behavior). While there are no results the panel stays open.
    private func installClickMonitors() {
        removeClickMonitors()
        let handle: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            guard !self.viewModel.allResults.isEmpty else { return event }
            let inWindow = event.window === panel
            let location = NSEvent.mouseLocation
            let outside = !panel.frame.contains(location)
            if inWindow || !outside { return event }
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
        viewModel.reset()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
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
}

enum ScreenUtils {
    static func screenContainingMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}
