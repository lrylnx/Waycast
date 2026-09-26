import Cocoa
import Carbon.HIToolbox

/// Global hotkey manager using the Carbon RegisterEventHotKey API.
/// Works without accessibility permission and is very lightweight.
final class HotkeyManager {
    enum HotkeyID: UInt32 {
        case search = 1
        case capture = 2
        /// 图片取字（对剪贴板里的图片做 OCR）。
        case ocrClipboard = 3
    }

    private var refs: [HotkeyID: EventHotKeyRef] = [:]
    private var handlers: [HotkeyID: @MainActor () -> Void] = [:]
    private var handlerInstalled = false
    /// 注册失败的 ID。
    ///
    /// ⚠️ 实测更正（2026-09-25）：Carbon 的排他性**只在同一个进程内可见** ——
    /// 拿两个独立进程各自注册同一个 F5，两边都返回 noErr、都注册成功，
    /// 都不会等到 eventHotKeyExistsErr。所以这个集合抓不到「被别的 App 占用」，
    /// 它实际只能反映**自己进程内**的重复注册。
    /// 「按了没反应」如果发生在别的 App 身上，在注册阶段是查不出来的。
    private(set) var failed: Set<HotkeyID> = []

    @discardableResult
    func register(id: HotkeyID, config: AppSettings.HotkeyConfig,
                  handler: @escaping @MainActor () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: OSType(0x48415047) /* 'HAPG' */, id: id.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(config.keyCode, config.modifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            refs[id] = ref
            handlers[id] = handler
            failed.remove(id)
            _ = hotKeyID
            return true
        } else {
            failed.insert(id)
            NSSound.beep()
            NSLog("[Waycast] 快捷键注册失败 %@（%@），status %d —— 多半被其他 App 占用了",
                  "\(id)", config.displayString, status)
            return false
        }
    }

    func unregister(id: HotkeyID) {
        failed.remove(id)
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
            refs[id] = nil
            handlers[id] = nil
        }
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let event = event, let userData = userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let id = HotkeyID(rawValue: hkID.id), let handler = manager.handlers[id] {
                // Carbon 的 application event target 回调本来就在主线程、主 runloop 上，
                // 所以正常情况下**直接同步调用**，不再排一次 DispatchQueue.main.async ——
                // 每多一次 hop 就多等最多一帧（16ms），截图这种要求"按下即响应"的路径上很致命。
                // 但仍然保留非主线程的分支：assumeIsolated 一旦判断错会直接崩进程，
                // 而这种低级崩溃不值得用 16ms 去换。
                if Thread.isMainThread {
                    MainActor.assumeIsolated { handler() }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
                }
            }
            return noErr
        }, 1, &spec, selfPtr, nil)
    }
}
