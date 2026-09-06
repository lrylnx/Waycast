import Cocoa
import Carbon.HIToolbox

/// Persistent user settings (hotkeys, clipboard limits) backed by UserDefaults.
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    struct HotkeyConfig: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier flags

        static func == (lhs: HotkeyConfig, rhs: HotkeyConfig) -> Bool {
            lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
        }
    }

    static let defaultSearch = HotkeyConfig(keyCode: UInt32(kVK_Space),
                                            modifiers: UInt32(cmdKey))
    static let defaultScreenshot = HotkeyConfig(keyCode: UInt32(kVK_F1), modifiers: 0)
    static let defaultPin = HotkeyConfig(keyCode: UInt32(kVK_F3), modifiers: 0)

    var searchHotkey: HotkeyConfig {
        get { hotkey(forKey: "searchHotkey", fallback: Self.defaultSearch) }
        set { set(hotkey: newValue, forKey: "searchHotkey") }
    }
    var screenshotHotkey: HotkeyConfig {
        get { hotkey(forKey: "screenshotHotkey", fallback: Self.defaultScreenshot) }
        set { set(hotkey: newValue, forKey: "screenshotHotkey") }
    }
    var pinHotkey: HotkeyConfig {
        get { hotkey(forKey: "pinHotkey", fallback: Self.defaultPin) }
        set { set(hotkey: newValue, forKey: "pinHotkey") }
    }

    /// Max clipboard text entries retained.
    var clipboardLimit: Int {
        get {
            let v = defaults.integer(forKey: "clipboardLimit")
            return v > 0 ? v : 50
        }
        set { defaults.set(newValue, forKey: "clipboardLimit") }
    }

    /// Search scopes: extra folders indexed alongside the whole disk.
    var searchScopePaths: [String] {
        get { defaults.stringArray(forKey: "searchScopePaths") ?? [] }
        set { defaults.set(newValue, forKey: "searchScopePaths") }
    }

    /// Status bar shows the memory waterline cup icon instead of the bolt.
    var statusIconWaterline: Bool {
        get { defaults.bool(forKey: "statusIconWaterline") }
        set { defaults.set(newValue, forKey: "statusIconWaterline") }
    }

    // MARK: - Search panel position (remembered per display)

    /// Stable-ish key for a display: name + pixel size. Survives re-plugging
    /// (unlike NSScreenNumber, which changes per connection).
    static func displayKey(_ screen: NSScreen) -> String {
        let f = screen.frame
        return "\(screen.localizedName)|\(Int(f.width))x\(Int(f.height))"
    }

    /// Top-left corner (AppKit global coords, y up) of the search panel.
    func searchPanelTopLeft(for key: String) -> NSPoint? {
        guard let a = defaults.array(forKey: "searchPanelPos.\(key)") as? [Double],
              a.count == 2 else { return nil }
        return NSPoint(x: a[0], y: a[1])
    }

    func setSearchPanelTopLeft(_ p: NSPoint, for key: String) {
        defaults.set([Double(p.x), Double(p.y)], forKey: "searchPanelPos.\(key)")
    }

    private func hotkey(forKey key: String, fallback: HotkeyConfig) -> HotkeyConfig {
        guard let data = defaults.data(forKey: key),
              let cfg = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else {
            return fallback
        }
        return cfg
    }

    private func set(hotkey: HotkeyConfig, forKey key: String) {
        if let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Human readable description

extension AppSettings.HotkeyConfig {
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCodes.name(for: keyCode)
        return s
    }
}

enum KeyCodes {
    static func name(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"; case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"; case kVK_Delete: return "Delete"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "Key(\(keyCode))"
        }
    }
}
