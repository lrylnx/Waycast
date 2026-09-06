import Cocoa
import Carbon.HIToolbox

/// Global hotkey manager using the Carbon RegisterEventHotKey API.
/// Works without accessibility permission and is very lightweight.
final class HotkeyManager {
    enum HotkeyID: UInt32 {
        case search = 1
        case screenshot = 2
        case pin = 3
    }

    private var refs: [HotkeyID: EventHotKeyRef] = [:]
    private var handlers: [HotkeyID: () -> Void] = [:]
    private var handlerInstalled = false

    func register(id: HotkeyID, config: AppSettings.HotkeyConfig, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: OSType(0x48415047) /* 'HAPG' */, id: id.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(config.keyCode, config.modifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            refs[id] = ref
            handlers[id] = handler
            _ = hotKeyID
        } else {
            NSSound.beep()
            NSLog("Waycast: failed to register hotkey \(id.rawValue), status \(status)")
        }
    }

    func unregister(id: HotkeyID) {
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
                DispatchQueue.main.async { handler() }
            }
            return noErr
        }, 1, &spec, selfPtr, nil)
    }
}
