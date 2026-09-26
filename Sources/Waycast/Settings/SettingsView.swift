import Cocoa
import Carbon.HIToolbox
import SwiftUI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Waycast 设置"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 560))
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Captures the next key combination for hotkey customization.
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var recordingTarget: SettingsView.Target?
    /// 按下的键不能当快捷键时给一句人话 —— 以前是**静默丢弃**，
    /// 用户只会觉得"没反应"。这个问题的另一半就在这儿。
    @Published var hint: String?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var timeoutWork: DispatchWorkItem?
    /// 录制期间把自己的全局热键摘掉了（见 `start()`），退出录制时要装回去。
    private var hotkeysSuspended = false

    func start(target: SettingsView.Target,
               window: NSWindow?,
               onCaptured: @escaping (SettingsView.Target, AppSettings.HotkeyConfig) -> Void) {
        teardown()
        isRecording = true
        recordingTarget = target
        hint = nil

        // 录制期间先把自己的全局热键摘掉。
        // 理由：想换绑「当前正被占用的那个键」时，你得先按一次它 —— 而全局热键
        // 优先于窗口里的按键监听，按下的一瞬间就直接触发了它的功能（比如弹出
        // 截图界面），根本轮不到录制器看到。摘掉最干净。
        AppDelegate.shared?.hotkeyManager?.unregisterAll()
        hotkeysSuspended = true

        // 顶排那排键走 MediaKeyBindings 的 event tap：
        //   · 亮度 / 音量 / 播放 / 背光 是 NX_SYSDEFINED 事件，普通按键监听看不到；
        //   · F1–F20 是 keyDown，但系统自己的功能键处理排在 Carbon / NSEvent 前面 ——
        //     只有 HID 层的 tap 抢得到。而且「媒体键模式」下 F3/F4 报的是 160/131
        //     这套扩展 keyCode，必须先归一再判断（见 KeyCodes.mediaModeKeyCodes）。
        // 两条都由同一个 tap 送过来。
        MediaKeyBindings.shared.beginRecording { [weak self] captured, isDown in
            guard isDown else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch captured {
                    case .special(let keyType):
                        self?.captureSpecial(keyType, target: target, onCaptured: onCaptured)
                    case .function(let keyCode):
                        self?.captureFunctionKey(keyCode, target: target, onCaptured: onCaptured)
                    }
                }
            }
        }

        // 录制期间 tap 一定是装着的（beginRecording 会确保）。装不上时先说清楚，
        // 别让人对着"按了没反应"发呆（需要「辅助功能」+「输入监控」两个权限）。
        if !MediaKeyBindings.shared.isInstalled {
            hint = "这次可能录不到顶排键：Waycast 没能装上全局按键监听。"
                + "请在「系统设置 › 隐私与安全性 › 辅助功能（以及输入监控）」里允许 Waycast，"
                + "然后重开这个设置窗口。"
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Self.handle(event, target: target, onCaptured: onCaptured, stopper: self)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Self.handle(event, target: target, onCaptured: onCaptured, stopper: self)
            return nil
        }

        // 兜底：用户录到一半直接关了设置窗口 → 全局热键必须装回去。
        // ⚠️ 只观察**设置窗口自己**的关闭。这里原来是 `object: nil` —— 任何窗口
        // 关闭（Toast 消失、OCR 结果窗、搜索面板…）都会把录制**静默停掉**：
        // 用户以为还在录制，再按 F1/F2 时走的已经是触发路径，截图覆盖层全屏
        // 弹出盖住设置窗口，看起来就像「窗口卡死关不掉」（2026-09-25 实测事故）。
        // 拿不到窗口时不装这个 observer —— 还有下面的超时兜底。
        if let window {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.stop() } }
                }
        }
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stop() } }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func stop() {
        teardown()
        if hotkeysSuspended {
            hotkeysSuspended = false
            AppDelegate.shared?.registerHotkeys()   // 按最新设置重新注册
        }
    }

    private func teardown() {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let ob = closeObserver {
            NotificationCenter.default.removeObserver(ob)
            closeObserver = nil
        }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        MediaKeyBindings.shared.endRecording()
        isRecording = false
        recordingTarget = nil
        hint = nil
    }

    /// 顶排特殊键：记成「它在顶排的位置（F1/F2…）」并打上 mediaKeyType 标记 ——
    /// 这类绑定不走 Carbon 注册，由 MediaKeyBindings 的 tap 接管。
    private func captureSpecial(_ keyType: Int,
                                target: SettingsView.Target,
                                onCaptured: @escaping (SettingsView.Target, AppSettings.HotkeyConfig) -> Void) {
        guard isRecording else { return }
        // ⚠️ 表外的 keyType **必须照样收**。这里原来是一句 `guard let virtualKey = …`
        // 挡着：查不到就弹个「暂不支持」然后丢掉 —— 而那正是 F3/F4 录不上的真凶。
        // 键盘代次不同，顶排键发的 NX_KEYTYPE 会变（本机 F3/F4 报 19/20，SDK 的
        // ev_keymap.h 里压根没有对应的「功能键」）。功能不该被一个名字卡住：
        // 位置给一个表外偏移值（只用于两条通道去重，不参与功能），绑定照存。
        let virtualKey = MediaKey.keyTypeToVirtualKey[keyType] ?? (10_000 + keyType)
        finish(target: target,
               config: AppSettings.HotkeyConfig(keyCode: UInt32(virtualKey),
                                                modifiers: 0,
                                                mediaKeyType: UInt32(keyType)),
               onCaptured: onCaptured)
    }

    /// 普通功能键（F1–F20）：由 tap 的 keyDown 通道送到这里。
    /// 不带 `mediaKeyType` —— 它是「F3」这颗键，不是「亮度 / 音量」那类特殊键；
    /// 触发时同样走 tap，不依赖 Carbon（F3/F4 那几颗 Carbon 根本收不到）。
    ///
    /// ⚠️ 落盘前一定要**归一到标准 keyCode**：媒体键模式下 F3 报的是 160、F4 报 131，
    /// 直接存下去的话，用户把键盘切回标准模式（或换外接键盘）后绑定就失效了。
    private func captureFunctionKey(_ keyCode: UInt32,
                                    target: SettingsView.Target,
                                    onCaptured: @escaping (SettingsView.Target, AppSettings.HotkeyConfig) -> Void) {
        guard isRecording else { return }
        let norm = keyCode <= UInt32(UInt16.max)
            ? UInt32(KeyCodes.normalizedTopRowKey(UInt16(keyCode))) : keyCode
        finish(target: target,
               config: AppSettings.HotkeyConfig(keyCode: norm, modifiers: 0),
               onCaptured: onCaptured)
    }

    private func finish(target: SettingsView.Target,
                        config: AppSettings.HotkeyConfig,
                        onCaptured: @escaping (SettingsView.Target, AppSettings.HotkeyConfig) -> Void) {
        stop()                        // 先把自己的全局热键装回去
        onCaptured(target, config)    // 再由调用方落盘 + 重新注册
    }

    nonisolated private static func handle(_ event: NSEvent,
                                           target: SettingsView.Target,
                                           onCaptured: @escaping (SettingsView.Target, AppSettings.HotkeyConfig) -> Void,
                                           stopper: HotkeyRecorder?) {
        let keyCode = event.keyCode

        // Esc 取消录制（裸 Esc 当全局热键本来也不是个好主意）。
        if keyCode == UInt16(kVK_Escape) {
            DispatchQueue.main.async { MainActor.assumeIsolated { stopper?.stop() } }
            return
        }

        let mods = carbonModifiers(from: event.modifierFlags)
        // 裸功能键也是合法的快捷键（F1 就是截图默认值）。
        // ⚠️ 这里必须用**集合**判断：F 键在 keyCode 空间里是乱序的
        // （F1=122、F12=111），`kVK_F1...kVK_F12` 是个空区间，一个都匹配不上 ——
        // 那正是「按 F2/F3 毫无反应、只有 ⌘⌃⌥+字母能识别」的原因。
        guard mods != 0 || KeyCodes.isTopRowKey(keyCode) else {
            // 以前这里直接 return，界面上毫无动静 —— 用户没法区分"没收到"
            // 和"收到了但不合格"。给一句能照做的提示。
            let name = KeyCodes.name(for: UInt32(keyCode))
            if name.hasPrefix("Key(") {
                // 纯修饰键、或我们不认识的功能键：不用提醒，继续等下一个键。
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    stopper?.hint = "「\(name)」不能单独当快捷键：请加 ⌘ / ⌃ / ⌥ / ⇧，或直接按 F1–F12。"
                }
            }
            return
        }

        let config = AppSettings.HotkeyConfig(keyCode: UInt32(keyCode), modifiers: mods)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                stopper?.finish(target: target, config: config, onCaptured: onCaptured)
            }
        }
    }

    nonisolated private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

/// Records a new AppRing summon shortcut through the ring's own event tap —
/// the only way to capture ⌘Tab itself without the system switcher popping.
/// SAFETY: while recording, the tap swallows EVERY keyDown system-wide, so
/// the handler is guaranteed to clear via Esc, a 10s timeout, window close,
/// or deinit.
@MainActor
final class AppRingShortcutRecorder: ObservableObject {
    @Published var isRecording = false
    private var timeoutWork: DispatchWorkItem?
    private var closeObserver: NSObjectProtocol?

    func start(window: NSWindow?) {
        stop()
        isRecording = true
        RingController.shared.setShortcutRecorder { [weak self] keyCode, flags in
            Task { @MainActor in self?.handle(keyCode, flags) }
        }
        // Hard timeout: never leave the global tap in recording mode.
        // ⚠️ 这里**故意强持有 self**：录制期间 ring 的 tap 会吞掉全系统每一个
        // keyDown，万一这个对象先被释放，`[weak self]` 的超时就变成空转，
        // 那个 handler 会**永远**留在 tap 上 —— 表现为「键盘彻底打不了字」。
        // 强持有让对象活到超时那一刻，保证一定能清掉。
        let work = DispatchWorkItem { [self] in stop() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        // Closing the settings window mid-recording must also restore the tap.
        // 只观察设置窗口自己的关闭（object: nil 会被任何窗口关闭误触发，见
        // HotkeyRecorder.start 里的同款事故记录）。
        if let window {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.stop() }
                }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        timeoutWork?.cancel()
        timeoutWork = nil
        if let ob = closeObserver { NotificationCenter.default.removeObserver(ob); closeObserver = nil }
        RingController.shared.setShortcutRecorder(nil)
    }

    private func handle(_ keyCode: Int, _ flags: CGEventFlags) {
        guard isRecording else { return }
        if keyCode == kVK_Escape { stop(); return }
        let mods = flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        // Require a modifier chord, or a bare function key.
        guard !mods.isEmpty || AppRingSettings.functionKeyCodes.contains(keyCode) else { return }
        AppRingSettings.summonModifiers = mods
        AppRingSettings.summonKeyCode = keyCode
        stop()
        NSSound.beep()
    }
}

struct SettingsView: View {
    @StateObject private var recorder = HotkeyRecorder()
    @StateObject private var ringRecorder = AppRingShortcutRecorder()
    @State private var ringEnabled = AppRingSettings.enabled
    @State private var ringSideButton = AppRingSettings.sideButtonEnabled
    @State private var searchKey = AppSettings.shared.searchHotkey
    @State private var captureKey = AppSettings.shared.captureHotkey
    @State private var ocrKey = AppSettings.shared.ocrHotkey
    @State private var ocrAutoCopy = AppSettings.shared.ocrAutoCopy
    @State private var ocrLanguage = AppSettings.shared.ocrLanguage
    @State private var ocrLayout = AppSettings.shared.ocrLayout
    @State private var clipboardLimit = AppSettings.shared.clipboardLimit
    @State private var captureDim = AppSettings.shared.captureDimOpacity
    @State private var statusIconMode = AppSettings.shared.statusIconMode
    @State private var autoStart = LaunchAtLogin.isEnabled
    @State private var autoStartError: String?
    @State private var topRowKeyDown = AppSettings.shared.topRowKeyDownChannel

    enum Target: Hashable { case search, capture, ocr }

    var body: some View {
        Form {
            Section {
                Toggle("开机自启动", isOn: $autoStart)
                    .onChange(of: autoStart) { newValue in
                        if let err = LaunchAtLogin.setEnabled(newValue) {
                            autoStartError = err
                            autoStart = LaunchAtLogin.isEnabled   // roll back UI
                        } else {
                            autoStartError = nil
                        }
                    }
                if let err = autoStartError {
                    Text("设置失败：\(err)")
                        .font(.caption).foregroundColor(.red)
                }
                Text("开启后登录 macOS 时自动启动 Waycast。若失败，请把应用移动到「应用程序」文件夹后重试。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("通用").font(.headline)
            }

            Section {
                hotkeyRow("搜索面板", display: searchKey.displayString, target: .search)
                hotkeyRow("截图", display: captureKey.displayString, target: .capture)
                hotkeyRow("图片取字（剪贴板）", display: ocrKey.displayString, target: .ocr)
                if !mediaBindingNotes().isEmpty {
                    Text(mediaBindingNotes())
                        .font(.caption).foregroundColor(.secondary)
                    Text(MediaKeyBindings.shared.isInstalled
                         ? "顶排特殊键的接管已生效 —— 按下会触发 Waycast，不再调节亮度/音量。"
                         : "特殊键接管不可用：请在「系统设置 → 隐私与安全性 → 辅助功能」里允许 Waycast，再重选一次。")
                        .font(.caption)
                        .foregroundColor(MediaKeyBindings.shared.isInstalled ? Color.secondary : Color.orange)
                }
                Text("「图片取字」对剪贴板里的图片直接做 OCR —— 不需要屏幕录制权限，也不用先进截图界面。截图后按它一次就出文字。")
                    .font(.caption).foregroundColor(.secondary)
                Text("想用顶排那排键：直接按就行。它们走的不是普通按键通道 —— 系统把它们"
                     + "当作「亮度/音量/播放/调度中心」这类特殊功能键发出来，Waycast 在系统"
                     + "动手之前截下来，所以接管后按下不再弹系统那个界面。"
                     + "亮度 / 音量那几颗会显示成「F2 · 亮度 +」（同一颗键位有两条事件通道，"
                     + "两条都接管）；认不出名字的显示成「顶排键（代码 19）」这类占位名，"
                     + "按下就是它，功能不受影响。"
                     + "想让那颗键恢复原样，换一组快捷键即可。")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("也接管裸 F 键（普通按键通道）", isOn: $topRowKeyDown)
                    .onChange(of: topRowKeyDown) { newValue in
                        AppSettings.shared.topRowKeyDownChannel = newValue
                        AppDelegate.shared?.registerHotkeys()
                    }
                Text("只在键盘被设成「将 F1、F2 等键用作标准功能键」时才需要打开 —— "
                     + "那种模式下顶排键不再发特殊功能键事件，只能走这条通道。"
                     + "代价：它会监听**所有**按键（2026-09-25 曾经因此把键盘整体卡死过），"
                     + "所以默认关闭；默认模式下打开它是多余的。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("全局快捷键").font(.headline)
            }

            Section {
                Toggle("识别后自动复制到剪贴板", isOn: $ocrAutoCopy)
                    .onChange(of: ocrAutoCopy) { AppSettings.shared.ocrAutoCopy = $0 }
                Picker("识别语言", selection: $ocrLanguage) {
                    ForEach(OcrLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }
                .onChange(of: ocrLanguage) { newValue in
                    AppSettings.shared.ocrLanguage = newValue
                    // 换语言等于换一套模型：后台先加载，免得下一次识别干等十几秒。
                    OcrService.warmUp(language: newValue)
                }
                Picker("结果排版", selection: $ocrLayout) {
                    ForEach(OcrLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .onChange(of: ocrLayout) { AppSettings.shared.ocrLayout = $0 }
                Text("引擎是 Apple Vision，跟系统「实况文本」同源：离线、免费、不联网、不需要密钥。识别入口有三个 —— 截图工具栏的「OCR 文字识别」按钮、状态栏菜单「图片取字」、以及上面的快捷键。识别结果可以在弹窗里直接改，也能当场换语言重算。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("文字识别 (OCR)").font(.headline)
            }

            Section {
                Toggle("启用环形应用切换器", isOn: $ringEnabled)
                    .onChange(of: ringEnabled) { newValue in
                        AppDelegate.shared.applyAppRingEnabled(newValue)
                    }
                HStack {
                    Text("呼出快捷键")
                    Spacer()
                    Button(ringRecorder.isRecording ? "请按下新快捷键…" : AppRingSettings.summonShortcutLabel) {
                        if ringRecorder.isRecording {
                            ringRecorder.stop()
                        } else {
                            ringRecorder.start(window: NSApp.keyWindow)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!ringEnabled)
                    .frame(minWidth: 130)
                    if ringRecorder.isRecording {
                        Button("取消") { ringRecorder.stop() }
                            .buttonStyle(.borderless)
                    }
                    Button("重置") {
                        ringRecorder.stop()
                        AppRingSettings.resetSummonShortcut()
                        ringRecorder.objectWillChange.send()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!ringEnabled)
                }
                Toggle("鼠标侧键呼出", isOn: $ringSideButton)
                    .onChange(of: ringSideButton) { newValue in
                        AppRingSettings.sideButtonEnabled = newValue
                        RingController.shared.sideButtonEnabled = newValue
                    }
                    .disabled(!ringEnabled)
                Text("按住修饰键、点按呼出键唤出圆环，松开即切换到选中的 App；默认 ⌘Tab 直接接管系统切换器。悬停多窗口应用会展开窗口花瓣（需屏幕录制权限显示缩略图）。关闭后 ⌘Tab 恢复系统行为。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("环形应用切换 (AppRing)").font(.headline)
            }

            Section {
                Picker("状态栏图标", selection: $statusIconMode) {
                    ForEach(StatusIconMode.allCases, id: \.self) { mode in
                        Text(mode.menuTitle).tag(mode)
                    }
                }
                .onChange(of: statusIconMode) { newValue in
                    StatusIconCenter.shared.select(newValue)
                }
                Text("默认显示闪电图标，也可换成内存水位杯、实时网速或 CPU 温度。四者互斥，只有当前选中的那个在采样，其余零开销。")
                    .font(.caption).foregroundColor(.secondary)
                Text("网速统计所有物理网卡（Wi-Fi / 有线 / 个人热点）的合计上下行；CPU 温度取所有 CPU 核心里最高的那一路。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("状态栏图标").font(.headline)
            }

            Section {
                Stepper(value: $clipboardLimit, in: 10...200, step: 10) {
                    HStack {
                        Text("剪贴板历史条数")
                        Spacer()
                        Text("\(clipboardLimit)").foregroundColor(.secondary)
                    }
                }
                Text("仅记录文本内容；点击记录即可重新复制到剪贴板。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("剪贴板").font(.headline)
            }
            .onChange(of: clipboardLimit) { AppSettings.shared.clipboardLimit = $0 }

            Section {
                HStack {
                    Text("选区外遮罩")
                    Slider(value: $captureDim, in: 0.1...0.8, step: 0.05)
                    Text("\(Int((captureDim * 100).rounded()))%")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("按 \(captureKey.displayString) 后，框选区域之外会被压暗这个比例——越暗，选区越突出。默认 45%。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("截图").font(.headline)
            }
            .onChange(of: captureDim) { AppSettings.shared.captureDimOpacity = $0 }

            Section {
                Text("截图（Mio 冻结帧方案）：按 \(captureKey.displayString) 后所有屏幕先定格成静帧，拖拽框选区域后点「复制 / OCR / 保存」；悬停时窗口会高亮，直接单击窗口即整窗截图（自带透明圆角），Shift+单击窗口则识别窗口内文字。Esc 或右键取消。")
                    .font(.caption).foregroundColor(.secondary)
                Text("标注：工具栏里选画笔 / 矩形 / 箭头 / 文字，标错了按 ⌘Z 撤销（也可以用工具栏那个回转箭头按钮）。")
                    .font(.caption).foregroundColor(.secondary)
                Text("取字：图在剪贴板里时（截图、复制图片、网上下载）按 ⌃⌥C 直接出文字，不经过截图界面；贴图上的小工具条也有 OCR 按钮。识别过程是离线的，图片不会外传。")
                    .font(.caption).foregroundColor(.secondary)
                Text("搜索：结果列表中的文件可直接拖拽到访达、邮件、聊天窗口等任意位置。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("使用提示").font(.headline)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    @ViewBuilder
    private func hotkeyRow(_ label: String, display: String, target: Target) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                if hotkeyTaken(target) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .help("这组快捷键没能注册成功 —— 换一组试试。")
                }
                Spacer()
                Button(recorder.recordingTarget == target ? "请按下快捷键…" : display) {
                    recorder.start(target: target, window: NSApp.keyWindow) { t, config in
                        apply(t, config)
                    }
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 130)
                if recorder.recordingTarget == target {
                    Button("取消") { recorder.stop() }
                        .buttonStyle(.borderless)
                }
            }
            if recorder.recordingTarget == target, let hint = recorder.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    /// 被接管的「特殊功能键」提示：这些键原本归系统调亮度/音量、或弹调度中心，绑定后由 Waycast 接管。
    private func mediaBindingNotes() -> String {
        let pairs: [(String, AppSettings.HotkeyConfig)] = [
            ("搜索面板", searchKey), ("截图", captureKey), ("图片取字", ocrKey),
        ]
        var notes: [String] = []
        var hasPairedKey = false
        for (name, cfg) in pairs {
            // 用 resolved：F1/F2/F5–F12 这类绑定即使没显式记 mediaKeyType，
            // 也会顺带接管同一颗物理键在「媒体键模式」下发出的 NX_SYSDEFINED。
            guard let keyType = cfg.mediaKeyTypeResolved else { continue }
            let label = MediaKey.label(for: Int(keyType))
            // 表外的特殊键（如 F3/F4 报的 19/20）没有对应的虚拟键码，位置是占位值。
            if cfg.keyCode > UInt32(UInt16.max) {
                notes.append("「\(label)」给了「\(name)」")
            } else {
                hasPairedKey = true
                notes.append("\(KeyCodes.name(for: cfg.keyCode)) 位置那颗键（顶排叫「\(label)」）给了「\(name)」")
            }
        }
        guard !notes.isEmpty else { return "" }
        var text = notes.joined(separator: "；") + "。这些键原本由系统处理，接管后按下触发 Waycast，不再执行原功能。"
        if hasPairedKey {
            text += "「F2 · 亮度 +」这种写法说的是**同一个键位**：同一条键位有两条事件通道 —— "
                + "不按 fn 时系统把它当特殊功能键发（名称是「亮度 +」），按住 fn 时是普通 F 键。"
                + "前者 Waycast 一定接管；后者只在上面「也接管裸 F 键」打开时才接管。"
        }
        return text + "想让那颗键恢复原样，换一组快捷键即可（调亮度可用控制中心）。"
    }

    /// 注册失败时给出如实提示（同进程内重复注册才会失败；跨进程的冲突
    /// Carbon 根本不报错，见 HotkeyManager 里的实测备注）。
    private func hotkeyTaken(_ target: Target) -> Bool {
        guard let manager = AppDelegate.shared?.hotkeyManager else { return false }
        // 特殊功能键走 event tap，不依赖 Carbon 注册 —— 别给它们误报"被占用"。
        let config: AppSettings.HotkeyConfig
        switch target {
        case .search:  config = searchKey
        case .capture: config = captureKey
        case .ocr:     config = ocrKey
        }
        // 走 event tap 的绑定不看 Carbon 的注册结果 —— Carbon 根本收不到它们，
        // "注册失败"是意料之中的。真正要确认的是 tap 本身装成了没有。
        // ⚠️ 判断必须用 **mediaKeyTypeResolved** 而不是 isMediaKey：像 F1 这类
        // 键位即使录制时没记下 mediaKeyType，媒体键模式下也会以 type 14 到达
        // （122 → keyType 3 能反查出来），tap 照样接管 —— 原来 fallback 到
        // isRawFunctionKey 分支会让这条「实际能用」的绑定误报感叹号
        // （2026-09-25 实测：用户绑 F1/F2 后 ⚠️ 常亮，以为绑定失败）。
        if config.mediaKeyTypeResolved != nil { return !MediaKeyBindings.shared.isInstalled }
        // 真·裸 F 键（反查不到 keyType 的）：走 keyDown 通道，那条默认是关的
        // （见 MediaKeyBindings 文件头的键盘卡死事故记录），没打开就等于没接管
        // —— 如实告诉用户，别让他干等。
        if config.isRawFunctionKey { return !MediaKeyBindings.shared.keyDownChannelActive }
        switch target {
        case .search:  return manager.failed.contains(.search)
        case .capture: return manager.failed.contains(.capture)
        case .ocr:     return manager.failed.contains(.ocrClipboard)
        }
    }

    private func apply(_ target: Target, _ value: AppSettings.HotkeyConfig) {
        let settings = AppSettings.shared
        switch target {
        case .search: settings.searchHotkey = value; searchKey = value
        case .capture: settings.captureHotkey = value; captureKey = value
        case .ocr: settings.ocrHotkey = value; ocrKey = value
        }
        AppDelegate.shared.registerHotkeys()
    }
}
