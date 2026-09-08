import Cocoa
import Carbon.HIToolbox
import SwiftUI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Waycast 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 400))
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
final class HotkeyRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var recordingTarget: SettingsView.Target?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start(target: SettingsView.Target,
               onCaptured: @escaping (SettingsView.Target, AppSettings.HotkeyConfig) -> Void) {
        stop()
        isRecording = true
        recordingTarget = target
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Self.handle(event, target: target, onCaptured: onCaptured, stopper: self)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Self.handle(event, target: target, onCaptured: onCaptured, stopper: self)
            return nil
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        isRecording = false
        recordingTarget = nil
    }

    private static func handle(_ event: NSEvent,
                               target: SettingsView.Target,
                               onCaptured: @escaping (SettingsView.Target, AppSettings.HotkeyConfig) -> Void,
                               stopper: HotkeyRecorder?) {
        let mods = carbonModifiers(from: event.modifierFlags)
        let isFunction = event.keyCode >= UInt16(kVK_F1) && event.keyCode <= UInt16(kVK_F12)
        guard mods != 0 || isFunction else { return }
        DispatchQueue.main.async {
            stopper?.stop()
            onCaptured(target, AppSettings.HotkeyConfig(keyCode: UInt32(event.keyCode),
                                                        modifiers: mods))
        }
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
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

    func start() {
        stop()
        isRecording = true
        RingController.shared.setShortcutRecorder { [weak self] keyCode, flags in
            Task { @MainActor in self?.handle(keyCode, flags) }
        }
        // Hard timeout: never leave the global tap in recording mode.
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        // Closing the settings window mid-recording must also restore the tap.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
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
    @State private var screenshotKey = AppSettings.shared.screenshotHotkey
    @State private var pinKey = AppSettings.shared.pinHotkey
    @State private var clipboardLimit = AppSettings.shared.clipboardLimit
    @State private var autoStart = LaunchAtLogin.isEnabled
    @State private var autoStartError: String?

    enum Target: Hashable { case search, screenshot, pin }

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
                hotkeyRow("截图", display: screenshotKey.displayString, target: .screenshot)
                hotkeyRow("贴图", display: pinKey.displayString, target: .pin)
            } header: {
                Text("全局快捷键").font(.headline)
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
                            ringRecorder.start()
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
                Text("截图：拖拽选择区域，双击或点「完成」复制到剪贴板；工具栏支持矩形、画笔、文字、箭头、马赛克、OCR、撤销、保存、贴图；选中工具后滚动滚轮调节粗细/字号。")
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
        HStack {
            Text(label)
            Spacer()
            Button(recorder.recordingTarget == target ? "请按下快捷键…" : display) {
                recorder.start(target: target) { t, config in
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
    }

    private func apply(_ target: Target, _ value: AppSettings.HotkeyConfig) {
        let settings = AppSettings.shared
        switch target {
        case .search: settings.searchHotkey = value; searchKey = value
        case .screenshot: settings.screenshotHotkey = value; screenshotKey = value
        case .pin: settings.pinHotkey = value; pinKey = value
        }
        AppDelegate.shared.registerHotkeys()
    }
}
