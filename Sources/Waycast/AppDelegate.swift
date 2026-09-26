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

    private(set) var hotkeyManager: HotkeyManager!
    /// 状态栏图标四个互斥选项（默认闪电 / 内存水位 / 网速 / CPU 温度）。
    private var statusIconItems: [StatusIconMode: NSMenuItem] = [:]
    /// 菜单里那三项要跟着快捷键配置走的条目（改快捷键后只更新它们的标题）。
    private var searchMenuItem: NSMenuItem?
    private var captureMenuItem: NSMenuItem?
    private var ocrClipboardMenuItem: NSMenuItem?
    /// 菜单里的「接管裸 F 键（keyDown 通道）」开关（勾选态跟着 `settings.topRowKeyDownChannel` 走）。
    private var topRowMenuItem: NSMenuItem?
    /// 菜单打开期间以 1Hz 刷新这几项的实时读数；菜单一关就销毁。
    private var statusIconReadingsTimer: Timer?
    /// Self-heals the AppRing event tap (the system disables it after sleep /
    /// login, or until Accessibility is granted).
    private var appRingTapTimer: Timer?
    /// 显示器拓扑变化通知的持有者（抓屏显示器列表缓存要跟着失效）。
    private var screenParamsObserver: NSObjectProtocol?
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

        // 插拔显示器 / 改分辨率后，抓屏用的显示器列表缓存必须作废。
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            FrozenCapture.invalidateDisplayCache()
        }

        // 预热文字识别模型：Vision 按语言加载，首次要十几秒。提前吃掉它，
        // 用户第一次点「提取文字」就不用干等。
        OcrService.warmUp(language: settings.ocrLanguage)

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

        // 开发者钩子：启动即打开搜索面板（验证面板 UI / 材质用，与上面的
        // WAYCAST_AUTO_CAPTURE 对称）。
        //   defaults write com.waycast.macos WAYCAST_AUTO_SEARCH -bool true
        // 可选再填一个查询词，面板会展开成「有结果」的样子（玻璃面积变大，
        // 是另一套视觉状态）：
        //   defaults write com.waycast.macos WAYCAST_AUTO_QUERY -string "切换"
        if UserDefaults.standard.bool(forKey: "WAYCAST_AUTO_SEARCH") {
            let delay = UserDefaults.standard.double(forKey: "WAYCAST_AUTO_SEARCH_DELAY")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 1.5)) { [weak self] in
                guard let self else { return }
                self.searchController.show()
                let query = UserDefaults.standard.string(forKey: "WAYCAST_AUTO_QUERY") ?? ""
                if !query.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.searchController.debugSetQuery(query)
                    }
                }
            }
        }

        // 开发者钩子：启动即对某个图片文件跑一次 OCR，把结果写日志（自动化验证用，
        // 不需要屏幕录制权限）。
        //   defaults write com.waycast.macos WAYCAST_OCR_FILE -string "/tmp/图片.png"
        //   defaults write com.waycast.macos WAYCAST_OCR_EXIT -bool true     # 出结果即退出
        //   defaults write com.waycast.macos WAYCAST_OCR_LANG -string "zhEn" # 可选
        //   defaults write com.waycast.macos WAYCAST_OCR_LAYOUT -string "paragraph" # 可选
        if let path = UserDefaults.standard.string(forKey: "WAYCAST_OCR_FILE") {
            let exitWhenDone = UserDefaults.standard.bool(forKey: "WAYCAST_OCR_EXIT")
            DispatchQueue.main.asyncAfter(deadline: .now() + (exitWhenDone ? 0.3 : 1.5)) {
                OcrEntry.debugRecognizeFile(path, exitWhenDone: exitWhenDone)
            }
        } else {
        }

        // 开发者钩子：自动进入截图态并**摆好一个假选区**（框选要人手，自动化验证
        // 看不到工具栏）。配合 WAYCAST_NO_CAPTURE 用，屏幕内容被换成纯灰，
        // 截图核对界面时不会拍到任何真实内容。
        //   defaults write com.waycast.macos WAYCAST_NO_CAPTURE -bool true
        //   defaults write com.waycast.macos WAYCAST_AUTO_CAPTURE_SELECT -float 0.45
        //   defaults write com.waycast.macos WAYCAST_AUTO_ANNOTATE -bool true
        if UserDefaults.standard.object(forKey: "WAYCAST_AUTO_CAPTURE_SELECT") != nil {
            let fraction = UserDefaults.standard.double(forKey: "WAYCAST_AUTO_CAPTURE_SELECT")
            if fraction > 0 {
                let annotate = UserDefaults.standard.bool(forKey: "WAYCAST_AUTO_ANNOTATE")
                let report = UserDefaults.standard.string(forKey: "WAYCAST_BENCH_OUT")
                    ?? "/tmp/waycast_undo_probe.txt"
                try? "Waycast probe — \(Date())\n".write(toFile: report, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.captureController.start()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                    guard let self else { return }
                    self.captureController.debugSelect(fraction: CGFloat(fraction), annotate: annotate)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    let c = self.captureController
                    c.debugLog("摆好选区：annotations=\(c.debugAnnotationCount)"
                               + "  第一响应者=\(c.debugFirstResponder.map { String(describing: type(of: $0)) } ?? "nil")",
                               to: report)
                }
                // 3.5s 时合成一次 ⌘Z（和真人按键同一条链路），再记一笔数量。
                if UserDefaults.standard.bool(forKey: "WAYCAST_AUTO_UNDO") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                        guard let self else { return }
                        let report = UserDefaults.standard.string(forKey: "WAYCAST_BENCH_OUT")
                            ?? "/tmp/waycast_undo_probe.txt"
                        self.captureController.debugLog("发送合成 ⌘Z…", to: report)
                        CaptureBench.synthCommandZ()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            guard let self else { return }
                            let n = self.captureController.debugAnnotationCount
                            self.captureController.debugLog(
                                "⌘Z 之后：annotations=\(n)  "
                                + (n == 1 ? "结论：⌘Z 生效 ✓" : "结论：⌘Z 没生效 ✗"),
                                to: report)
                            if UserDefaults.standard.bool(forKey: "WAYCAST_BENCH_EXIT") {
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }

        // 开发者钩子：截图延迟基准测试（拆解「按 F1 → 覆盖层可见」的耗时构成）。
        //   defaults write com.waycast.macos WAYCAST_CAPTURE_BENCH -bool true
        //   defaults write com.waycast.macos WAYCAST_CAPTURE_BENCH_EXIT -bool true
        if UserDefaults.standard.bool(forKey: "WAYCAST_CAPTURE_BENCH") {
            let exitWhenDone = UserDefaults.standard.bool(forKey: "WAYCAST_CAPTURE_BENCH_EXIT")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureBench.run(iterations: 5, exitWhenDone: exitWhenDone)
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

        // 标题里的按键提示跟着实际配置走 —— 之前是硬编码的，改了快捷键菜单还写着旧键。
        let search = NSMenuItem(title: "搜索  \(settings.searchHotkey.displayString)",
                                action: #selector(showSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        searchMenuItem = search

        let shot = NSMenuItem(title: "截图  \(settings.captureHotkey.displayString)",
                              action: #selector(startCapture), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)
        captureMenuItem = shot

        let ocrClip = NSMenuItem(title: "图片取字（剪贴板）  \(settings.ocrHotkey.displayString)",
                                 action: #selector(ocrFromClipboard), keyEquivalent: "")
        ocrClip.target = self
        menu.addItem(ocrClip)
        ocrClipboardMenuItem = ocrClip

        let ocrFile = NSMenuItem(title: "图片取字（选择文件…）",
                                 action: #selector(ocrFromFile), keyEquivalent: "")
        ocrFile.target = self
        menu.addItem(ocrFile)

        menu.addItem(.separator())

        let lock = NSMenuItem(title: "锁定输入法", action: #selector(toggleInputLock), keyEquivalent: "")
        lock.target = self
        lock.state = InputSourceLock.shared.isLocked ? .on : .off
        menu.addItem(lock)
        InputSourceLock.shared.onChange = { [weak lock] in
            lock?.state = InputSourceLock.shared.isLocked ? .on : .off
        }

        // 「接管裸 F 键（keyDown 通道）」开关。
        //
        // 为什么单独列出来：这条通道要遮住整条 keyDown / keyUp，是全应用里风险最高的
        // 一处（见 MediaKeyBindings 文件头的事故记录 —— 之前的版本就是它把键盘整体卡死）。
        // 所以它默认关，并且**必须有一个不用键盘、用鼠标点一下就能关掉的入口**：
        // 万一又出现「按键没反应」，这里点一下立刻恢复（关掉后 tap 最多只收 type 14）。
        //
        // 平时什么时候需要它：键盘被设成「将 F1、F2 等键用作标准功能键」时，顶排键
        // 不再发 NX_SYSDEFINED，只能靠这条通道接。本机默认（媒体键模式）用不上。
        let topRow = NSMenuItem(title: "接管裸 F 键（keyDown 通道，键盘异常时可关掉）",
                                action: #selector(toggleTopRowKeyDownChannel),
                                keyEquivalent: "")
        topRow.target = self
        topRow.state = settings.topRowKeyDownChannel ? .on : .off
        menu.addItem(topRow)
        topRowMenuItem = topRow

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
        // 热键回调是**同步**跑在主线程上的（见 HotkeyManager），所以这里别提 Task
        // 再兜一层 —— 每多一次 hop 就多等最多一帧，截图最吃亏。
        // 闭包一律 [weak self]：hotkeyManager 由 delegate 持有，闭包再强引用
        // delegate 就成环了。
        hotkeyManager.register(id: .search, config: settings.searchHotkey) { [weak self] in
            guard let self, !self.suspendedByStatusMenu() else { return }
            self.searchController.toggle()
        }
        hotkeyManager.register(id: .capture, config: settings.captureHotkey) { [weak self] in
            guard let self, !self.suspendedByStatusMenu() else { return }
            self.captureController.start()
        }
        hotkeyManager.register(id: .ocrClipboard, config: settings.ocrHotkey) { [weak self] in
            guard let self, !self.suspendedByStatusMenu() else { return }
            OcrEntry.recognizeClipboard()
        }

        // 顶排「特殊功能键」（亮度 / 音量 / 播放…）在 macOS 上是 NX_SYSDEFINED 事件，
        // Carbon 的 RegisterEventHotKey 抓不到它们 —— 这类绑定改由 MediaKeyBindings
        // 的 event tap 接管。没绑任何特殊键时那个 tap 根本不会安装，行为与以前一致。
        // （同时仍然按 F 键位置做一次 Carbon 注册：这样按住 fn 再按时也多一条触发路径。）
        // 绑定 F1/F2/F5–F12 时会**自动**接管同一颗键在媒体键模式下的 NX_SYSDEFINED
        // —— 见 HotkeyConfig.mediaKeyTypeResolved。
        //
        // 第二条通道是**裸功能键**（F1–F20 的 keyDown）：只有键盘被设成「标准功能键
        // 模式」时顶排键才会这样进来。**默认关** —— 这条通道要遮住所有按键，风险最高，
        // 2026-09-25 曾因此把用户键盘整体卡死（见 MediaKeyBindings 文件头）。
        // 本机默认（媒体键模式）完全用不上它：实测顶排键全是 type 14。
        //
        // ⚠️ 登记时把 keyCode **归一到标准模式那套**：顶排键有标准 / 媒体键模式两套
        // keyCode，归一后同一个绑定在两种模式下都成立。
        // 同一个动作可能在两条通道里都出现 —— 比如 F2：不按 fn 时是「亮度 +」，
        // 换成普通外接键盘按就是普通的 F2，两条都该触发截图。
        var mediaActions: [Int: @MainActor () -> Void] = [:]
        var functionActions: [UInt32: @MainActor () -> Void] = [:]

        let searchAction: @MainActor () -> Void = { [weak self] in
            guard let self, !self.suspendedByStatusMenu() else { return }
            self.searchController.toggle()
        }
        let captureAction: @MainActor () -> Void = { [weak self] in
            guard let self, !self.suspendedByStatusMenu() else { return }
            self.captureController.start()
        }
        let ocrAction: @MainActor () -> Void = { [weak self] in
            guard let self, !self.suspendedByStatusMenu() else { return }
            OcrEntry.recognizeClipboard()
        }

        let bindings: [(AppSettings.HotkeyConfig, @MainActor () -> Void)] = [
            (settings.searchHotkey, searchAction),
            (settings.captureHotkey, captureAction),
            (settings.ocrHotkey, ocrAction),
        ]
        for (config, action) in bindings {
            if let keyType = config.mediaKeyTypeResolved { mediaActions[Int(keyType)] = action }
            if config.isRawFunctionKey {
                // 归一化后再登记，兼容历史配置里可能存着的媒体模式 keyCode。
                let norm = config.keyCode <= UInt32(UInt16.max)
                    ? UInt32(KeyCodes.normalizedTopRowKey(UInt16(config.keyCode)))
                    : config.keyCode
                functionActions[norm] = action
            }
        }
        MediaKeyBindings.shared.setKeyDownChannel(settings.topRowKeyDownChannel)
        MediaKeyBindings.shared.update(mediaActions: mediaActions,
                                       functionActions: functionActions)
        // 注册失败的组合键是**静默**失效的（被别的 App 占了），这里主动记一笔。
        if !hotkeyManager.failed.isEmpty {
            let names = hotkeyManager.failed.map { "\($0)" }.joined(separator: ", ")
            NSLog("[Waycast] 以下快捷键未能注册（可能被其他 App 占用）：%@", names)
        }
        refreshStatusMenu()
    }

    /// 快捷键改动后更新菜单里的按键提示。
    ///
    /// 这里**只改标题**，绝不替换整个 `statusItem.menu` —— 曾经在启动阶段做
    /// `statusItem.menu = 新菜单`，`applicationDidFinishLaunching` 会在那一行
    /// 停住不再返回（后续初始化全部不执行）。就地改标题既够用又没有这个坑。
    func refreshStatusMenu() {
        searchMenuItem?.title = "搜索  \(settings.searchHotkey.displayString)"
        captureMenuItem?.title = "截图  \(settings.captureHotkey.displayString)"
        ocrClipboardMenuItem?.title = "图片取字（剪贴板）  \(settings.ocrHotkey.displayString)"
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
    @objc private func ocrFromClipboard() { OcrEntry.recognizeClipboard() }
    @objc private func ocrFromFile() { OcrEntry.recognizeImageFiles() }
    @objc private func toggleInputLock() { InputSourceLock.shared.toggle() }

    /// 「接管裸 F 键（keyDown 通道）」开关 —— 见 `buildStatusMenu()` 里的说明。
    /// 这是键盘万一出怪问题时**唯一不用键盘的出口**，所以菜单项必须一直可达。
    @objc private func toggleTopRowKeyDownChannel() {
        let on = !settings.topRowKeyDownChannel
        settings.topRowKeyDownChannel = on
        MediaKeyBindings.shared.setKeyDownChannel(on)
        topRowMenuItem?.state = on ? .on : .off
    }

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
        // 「接管裸 F 键」在两处能改（设置界面 + 这个菜单），勾选态以设置为准 ——
        // 菜单是一次性建好的，不在这里同步的话，从设置里改过之后勾就会骗人。
        topRowMenuItem?.state = settings.topRowKeyDownChannel ? .on : .off
        startStatusIconReadings()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuTracking = false
        statusMenuClosedAt = Date()
        stopStatusIconReadings()
    }
}
