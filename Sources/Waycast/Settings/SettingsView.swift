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

struct SettingsView: View {
    @StateObject private var recorder = HotkeyRecorder()
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
