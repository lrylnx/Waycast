import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    let settings = AppSettings.shared
    private(set) var statusItem: NSStatusItem!

    // Feature controllers
    private(set) lazy var searchController = SpotlightController()
    private(set) lazy var screenshotController = ScreenshotController()
    private(set) lazy var clipboardController = ClipboardController()

    private var hotkeyManager: HotkeyManager!
    private weak var waterlineItem: NSMenuItem?
    /// True while the status-bar menu is open. A hotkey pressed during menu
    /// tracking runs its handler inside (or right after) the menu's nested
    /// event loop, where the screenshot overlay can't become key — the old
    /// race that froze the screen behind an undismissable overlay.
    private var statusMenuTracking = false
    private var statusMenuClosedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = buildMainMenu()

        hotkeyManager = HotkeyManager()
        setupStatusItem()
        registerHotkeys()
        clipboardController.start()

        // Warm up the app index and Spotlight so the first invocation is fast.
        searchController.warmUp()

        // First-run guidance for required permissions.
        if !CGPreflightScreenCaptureAccess() {
            showScreenCapturePermissionAlert()
        }
    }

    /// Minimal main menu. Accessory apps get no default menu, which is why
    /// ⌘C/⌘A in the OCR text view did nothing — those are menu-driven key
    /// equivalents. autoenablesItems stays ON so items only fire when the
    /// first responder actually implements the action (the overlay's own
    /// ⌘C/⌘Z handlers in keyDown keep working otherwise).
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        winItem.submenu = win
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        return main
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.defaultStatusImage()
        }
        statusItem.menu = buildStatusMenu()
        statusItem.menu?.delegate = self

        // Memory waterline icon (opt-in): pushes new frames into the button,
        // nil restores the default bolt.
        MemoryWaterline.shared.onIconUpdate = { [weak self] image in
            self?.statusItem.button?.image = image ?? Self.defaultStatusImage()
        }
        MemoryWaterline.shared.onChange = { [weak self] in
            self?.waterlineItem?.state = MemoryWaterline.shared.isEnabled ? .on : .off
        }
    }

    private static func defaultStatusImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "bolt.horizontal.circle",
                            accessibilityDescription: "Waycast")
        image?.isTemplate = true
        return image
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let search = NSMenuItem(title: "搜索  ⌥Space", action: #selector(showSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)

        let shot = NSMenuItem(title: "截图  F1", action: #selector(startScreenshot), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        let pin = NSMenuItem(title: "贴图  F3", action: #selector(startPinCapture), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        menu.addItem(.separator())

        let lock = NSMenuItem(title: "锁定输入法", action: #selector(toggleInputLock), keyEquivalent: "")
        lock.target = self
        lock.state = InputSourceLock.shared.isLocked ? .on : .off
        menu.addItem(lock)
        InputSourceLock.shared.onChange = { [weak lock] in
            lock?.state = InputSourceLock.shared.isLocked ? .on : .off
        }

        // 勾选后状态栏换成内存水位杯图标，再点一次切回默认闪电图标。
        let water = NSMenuItem(title: "内存水位图标", action: #selector(toggleWaterline), keyEquivalent: "")
        water.target = self
        water.state = MemoryWaterline.shared.isEnabled ? .on : .off
        menu.addItem(water)
        waterlineItem = water

        menu.addItem(.separator())

        let clip = NSMenuItem(title: "剪贴板历史", action: nil, keyEquivalent: "")
        clip.submenu = clipboardController.menu
        menu.addItem(clip)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "退出 Waycast", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Hotkeys

    func registerHotkeys() {
        hotkeyManager.unregisterAll()
        hotkeyManager.register(id: .search, config: settings.searchHotkey) {
            Task { @MainActor in
                guard !self.suspendedByStatusMenu() else { return }
                self.searchController.toggle()
            }
        }
        hotkeyManager.register(id: .screenshot, config: settings.screenshotHotkey) {
            Task { @MainActor in
                guard !self.suspendedByStatusMenu() else { return }
                self.screenshotController.start(mode: .annotate)
            }
        }
        hotkeyManager.register(id: .pin, config: settings.pinHotkey) {
            Task { @MainActor in
                guard !self.suspendedByStatusMenu() else { return }
                self.screenshotController.start(mode: .pin)
            }
        }
    }

    /// Hotkeys are ignored while the status menu is open and for a short
    /// cooldown after it closes, so a press never launches a UI whose window
    /// cannot take key focus from the still-tearing-down menu tracking loop.
    private func suspendedByStatusMenu() -> Bool {
        if statusMenuTracking { return true }
        if let t = statusMenuClosedAt, Date().timeIntervalSince(t) < 0.4 { return true }
        return false
    }

    @objc private func showSearch() { searchController.toggle() }
    @objc private func startScreenshot() { screenshotController.start(mode: .annotate) }
    @objc private func startPinCapture() { screenshotController.start(mode: .pin) }
    @objc private func toggleInputLock() { InputSourceLock.shared.toggle() }
    @objc private func toggleWaterline() { MemoryWaterline.shared.toggle() }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Permissions

    private func showScreenCapturePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "截图功能需要「屏幕录制」权限。\n请在 系统设置 › 隐私与安全性 › 屏幕录制 中勾选 Waycast，然后重新启动应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Status menu tracking

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        statusMenuTracking = true
        statusMenuClosedAt = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuTracking = false
        statusMenuClosedAt = Date()
    }
}
