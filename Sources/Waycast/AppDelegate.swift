import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    let settings = AppSettings.shared
    private(set) var statusItem: NSStatusItem!

    // Feature controllers
    private(set) lazy var searchController = SpotlightController()
    private(set) lazy var clipboardController = ClipboardController()
    private(set) lazy var captureController = CaptureController()

    private var hotkeyManager: HotkeyManager!
    /// 状态栏图标四个互斥选项（默认闪电 / 内存水位 / 网速 / CPU 温度）。
    private var statusIconItems: [StatusIconMode: NSMenuItem] = [:]
    /// 菜单打开期间以 1Hz 刷新这几项的实时读数；菜单一关就销毁。
    private var statusIconReadingsTimer: Timer?
    /// Self-heals the AppRing event tap (the system disables it after sleep /
    /// login, or until Accessibility is granted).
    private var appRingTapTimer: Timer?
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

        // Prewarm ScreenCaptureKit so the first frozen capture is fast (Mio-style).
        Task { await FrozenCapture.prewarm() }

        // Warm the capture overlay panel pool now (invisible windows) so the
        // first F1 never orders a new window front — macOS 26 zoom-animates
        // new windows, and a fullscreen overlay opening reads as the whole
        // screen zooming.
        _ = captureController

        // AppRing radial switcher (opt-out via settings; default on).
        startAppRing()

        // First-run guidance for required permissions.
        checkDocumentsAccess()

        // 开发者钩子：启动即进入截图态（配合 WAYCAST_NO_CAPTURE 做 UI 隔离测试）。
        //   defaults write com.waycast.macos WAYCAST_AUTO_CAPTURE -bool true
        // 用 defaults 而非环境变量：从终端直接跑可执行文件会把 TCC 屏幕录制
        // 权限算到终端头上，截图会失败。
        if UserDefaults.standard.bool(forKey: "WAYCAST_AUTO_CAPTURE") {
            let delay = UserDefaults.standard.double(forKey: "WAYCAST_AUTO_CAPTURE_DELAY")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 1.0)) { [weak self] in
                self?.captureController.start()
            }
        }
    }

    // MARK: - AppRing (radial app switcher)

    /// Bring up the ring switcher and keep its event tap alive. The tap needs
    /// the Accessibility permission; until it's granted `install()` fails, so a
    /// light timer retries every couple seconds (also self-heals after sleep).
    private func startAppRing() {
        MRUModel.shared.start()
        RingController.shared.start()
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        appRingTapTimer?.invalidate()
        appRingTapTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in _ = RingController.shared.ensureTap() }
        }
    }

    /// Apply the AppRing master toggle from the settings window: start the tap
    /// when enabled, tear it down (reverting ⌘Tab to the system) when disabled.
    func applyAppRingEnabled(_ enabled: Bool) {
        AppRingSettings.enabled = enabled
        if enabled {
            RingController.shared.start()
        } else {
            RingController.shared.stop()
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

        // 状态栏图标总控：内存水位 / 网速 / CPU 温度 四选一，没启用的
        // provider 定时器是 nil，不采样也不重绘。
        StatusIconCenter.shared.onImageChange = { [weak self] image in
            self?.statusItem.button?.image = image ?? Self.defaultStatusImage()
        }
        StatusIconCenter.shared.onModeChange = { [weak self] in
            self?.syncStatusIconMenu()
        }
        StatusIconCenter.shared.start()
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

        let shot = NSMenuItem(title: "截图  F1", action: #selector(startCapture), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        menu.addItem(.separator())

        let lock = NSMenuItem(title: "锁定输入法", action: #selector(toggleInputLock), keyEquivalent: "")
        lock.target = self
        lock.state = InputSourceLock.shared.isLocked ? .on : .off
        menu.addItem(lock)
        InputSourceLock.shared.onChange = { [weak lock] in
            lock?.state = InputSourceLock.shared.isLocked ? .on : .off
        }

        // 状态栏图标：四选一。勾选后状态栏换成对应读数，再点一次切回默认闪电图标。
        // 菜单打开期间这几项还会带上实时读数（内存水位 42% / 网速 ↓1.2 MB/s / CPU 温度 48°C）。
        for target in StatusIconMode.allCases {
            let item = NSMenuItem(title: target.menuTitle,
                                  action: #selector(selectStatusIcon(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            item.state = StatusIconCenter.shared.mode == target ? .on : .off
            menu.addItem(item)
            statusIconItems[target] = item
        }

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
        hotkeyManager.register(id: .capture, config: settings.captureHotkey) {
            Task { @MainActor in
                guard !self.suspendedByStatusMenu() else { return }
                self.captureController.start()
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
    @objc private func startCapture() { captureController.start() }
    @objc private func toggleInputLock() { InputSourceLock.shared.toggle() }

    @objc private func selectStatusIcon(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = StatusIconMode(rawValue: raw) else { return }
        StatusIconCenter.shared.toggle(target)
    }

    private func syncStatusIconMenu() {
        for target in StatusIconMode.allCases {
            guard let item = statusIconItems[target] else { continue }
            item.state = StatusIconCenter.shared.mode == target ? .on : .off
            item.title = target.menuTitle
        }
    }

    // MARK: - 菜单里的实时读数

    private func startStatusIconReadings() {
        StatusIconCenter.shared.primeMenuReadings()
        refreshStatusIconReadings()
        guard statusIconReadingsTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // 定时器挂在主 RunLoop 上，这里一定在主线程；assumeIsolated 避免
            // 再排一次 Task（菜单读数要的是"马上刷新"）。
            MainActor.assumeIsolated { self?.refreshStatusIconReadings() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        statusIconReadingsTimer = t
    }

    private func stopStatusIconReadings() {
        statusIconReadingsTimer?.invalidate()
        statusIconReadingsTimer = nil
        // 关闭后把读数后缀去掉，菜单回到干净的形态。
        for target in StatusIconMode.allCases {
            statusIconItems[target]?.title = target.menuTitle
        }
    }

    private func refreshStatusIconReadings() {
        for target in StatusIconMode.allCases {
            guard let item = statusIconItems[target] else { continue }
            if let reading = StatusIconCenter.shared.reading(for: target) {
                item.title = "\(target.menuTitle)  \(reading)"
            } else {
                item.title = target.menuTitle
            }
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Permissions

    /// Unlike Accessibility / ScreenCapture, the TCC "Documents folder"
    /// grant has NO proactive-request API: the system only prompts on actual
    /// file access from a user-initiated context, and silently denies
    /// background access — which is why file-search results under
    /// ~/Documents used to vanish with no explanation. Touching the folder
    /// on the MAIN thread at launch is the only way to raise the one-time
    /// system prompt; if the grant was already decided (denied or lost to an
    /// ad-hoc rebuild), the probe fails and we route the user to Settings
    /// ourselves, mirroring the screen-capture guidance above.
    private func checkDocumentsAccess() {
        let docs = NSHomeDirectory() + "/Documents"
        // This touch may itself raise the one-time TCC prompt.
        _ = try? FileManager.default.contentsOfDirectory(atPath: docs)
        // Give a just-shown system prompt a moment to be answered before
        // concluding the grant is missing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard (try? FileManager.default.contentsOfDirectory(atPath: docs)) == nil else { return }
            guard self != nil else { return }
            let alert = NSAlert()
            alert.messageText = "需要「文稿」文件夹访问权限"
            alert.informativeText = "文件搜索需要访问「文稿」文件夹。\n请在 系统设置 › 隐私与安全性 › 完全磁盘访问权限 中打开 Waycast（若无开关，先添加 /Applications/Waycast.app），然后重新启动应用。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Status menu tracking

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        statusMenuTracking = true
        statusMenuClosedAt = nil
        startStatusIconReadings()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuTracking = false
        statusMenuClosedAt = Date()
        stopStatusIconReadings()
    }
}
