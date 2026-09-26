import Cocoa
import Carbon.HIToolbox

/// Persistent user settings (hotkeys, clipboard limits) backed by UserDefaults.
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    struct HotkeyConfig: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier flags
        /// 非 nil 表示这个快捷键是按「顶排特殊功能键」（亮度 / 音量 / 播放…）录进来的。
        ///
        /// 这类键在 macOS 上根本不是 keyDown，而是 NX_SYSDEFINED 事件，Carbon 的
        /// RegisterEventHotKey 抓不到 —— 只能由 `MediaKeyBindings` 的 event tap 接管。
        /// 值就是 NX_KEYTYPE（见 MediaKey）。keyCode 仍然填它在顶排的位置（F1/F2…），
        /// 这样显示和冲突判断都还能用。
        var mediaKeyType: UInt32? = nil

        /// 这个绑定是否走「特殊功能键」那条 tap 通道。
        var isMediaKey: Bool { mediaKeyType != nil }

        /// 裸顶排功能键（F1–F20，不带 ⌘⌃⌥⇧）—— 由 event tap 接管，走 keyDown 通道。
        ///
        /// 为什么它们也不能交给 Carbon：Carbon 的 `RegisterEventHotKey` 只在应用层，
        /// 系统自己的功能键处理排在它前面 —— 实测症状是「绑了毫无反应，系统功能照常弹」。
        /// 只有把 tap 下沉到 `.cghidEventTap`（事件刚进 window server 的那一刻）才抢得到。
        ///
        /// ⚠️ 判断必须用 `isTopRowKey`（两种键盘模式的两套 keyCode），不能只用
        /// `isFunctionKey`：媒体键模式下 F3（调度中心）报的是 keyCode **160**、
        /// F4 报 **131**，都不在标准那套里 —— 只认标准码就会把它们当"普通按键"放行。
        var isRawFunctionKey: Bool {
            modifiers == 0 && keyCode <= UInt32(UInt16.max)
                && KeyCodes.isTopRowKey(UInt16(keyCode))
        }

        static func == (lhs: HotkeyConfig, rhs: HotkeyConfig) -> Bool {
            lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
                && lhs.mediaKeyType == rhs.mediaKeyType
        }
    }

    static let defaultSearch = HotkeyConfig(keyCode: UInt32(kVK_Space),
                                            modifiers: UInt32(cmdKey))
    static let defaultCapture = HotkeyConfig(keyCode: UInt32(kVK_F1), modifiers: 0)
    /// 图片取字（剪贴板）。⌃⌥C —— 不碰任何系统快捷键，也基本不会和应用冲突。
    static let defaultOcr = HotkeyConfig(keyCode: UInt32(kVK_ANSI_C),
                                         modifiers: UInt32(controlKey | optionKey))

    var searchHotkey: HotkeyConfig {
        get { hotkey(forKey: "searchHotkey", fallback: Self.defaultSearch) }
        set { set(hotkey: newValue, forKey: "searchHotkey") }
    }
    var captureHotkey: HotkeyConfig {
        get { hotkey(forKey: "captureHotkey", fallback: Self.defaultCapture) }
        set { set(hotkey: newValue, forKey: "captureHotkey") }
    }
    var ocrHotkey: HotkeyConfig {
        get { hotkey(forKey: "ocrHotkey", fallback: Self.defaultOcr) }
        set { set(hotkey: newValue, forKey: "ocrHotkey") }
    }

    /// 是否连「以 keyDown 进来的裸 F 键」一起接管。
    ///
    /// **默认关**，因为这条通道要遮住**所有**按键：2026-09-25 把它挂在 HID 层、
    /// 回调里又建对象+写日志，直接把用户整个键盘卡死（只能用鼠标强退）。
    /// 现在虽然已经退回会话层、回调也只剩整数运算，但它仍然是全应用里风险最高的
    /// 一处 —— 能不遮就不遮。
    ///
    /// 什么时候才需要打开：键盘被设成「将 F1、F2 等键用作标准功能键」时，顶排键
    /// 不再发 NX_SYSDEFINED，只能靠这条通道接。本机默认（媒体键模式）用不上它：
    /// 实测日志里顶排键全是 type 14。
    var topRowKeyDownChannel: Bool {
        get { defaults.bool(forKey: "topRowKeyDownChannel") }
        set { defaults.set(newValue, forKey: "topRowKeyDownChannel") }
    }

    // MARK: - OCR

    /// 识别完成后自动把结果写进剪贴板。默认开 —— 取字这件事十有八九就是要粘贴。
    var ocrAutoCopy: Bool {
        get {
            guard defaults.object(forKey: "ocrAutoCopy") != nil else { return true }
            return defaults.bool(forKey: "ocrAutoCopy")
        }
        set { defaults.set(newValue, forKey: "ocrAutoCopy") }
    }

    var ocrLanguage: OcrLanguage {
        get {
            if let raw = defaults.string(forKey: "ocrLanguage"),
               let value = OcrLanguage(rawValue: raw) {
                return value
            }
            return .zhEn
        }
        set { defaults.set(newValue.rawValue, forKey: "ocrLanguage") }
    }

    var ocrLayout: OcrLayout {
        get {
            if let raw = defaults.string(forKey: "ocrLayout"),
               let value = OcrLayout(rawValue: raw) {
                return value
            }
            return .lines
        }
        set { defaults.set(newValue.rawValue, forKey: "ocrLayout") }
    }

    /// 截图时选区之外区域的变暗强度，0…1（1 = 全黑）。
    /// 默认 0.45 —— 足以让选区「跳出来」，又不至于看不清底下的内容。
    var captureDimOpacity: Double {
        get {
            guard defaults.object(forKey: "captureDimOpacity") != nil else { return 0.45 }
            return min(1, max(0, defaults.double(forKey: "captureDimOpacity")))
        }
        set { defaults.set(min(1, max(0, newValue)), forKey: "captureDimOpacity") }
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

    /// 状态栏图标模式（默认闪电 / 内存水位 / 网速 / CPU 温度，四者互斥）。
    var statusIconMode: StatusIconMode {
        get {
            if let raw = defaults.string(forKey: "statusIconMode"),
               let mode = StatusIconMode(rawValue: raw) {
                return mode
            }
            // 老版本只有一个 Bool 开关（内存水位图标），迁移一次。
            return defaults.bool(forKey: "statusIconWaterline") ? .memory : .bolt
        }
        set { defaults.set(newValue.rawValue, forKey: "statusIconMode") }
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
    /// 真正要被 event tap 接管的 NX_KEYTYPE（nil = 走普通 Carbon 热键）。
    ///
    /// `mediaKeyType` 只在「录键时按的就是特殊键」时才有值；但**同一颗物理键**在
    /// 「媒体键模式」下（多数 Mac 的默认设置）按下去发的是 NX_SYSDEFINED，按住 fn
    /// 才是普通 keyDown。既然两条路都是同一颗键，绑定就得两条都收 —— 否则会出现
    /// 「F2 明明绑了截图，却只有 fn+F2 好使」这种半残状态（实测踩过）。
    var mediaKeyTypeResolved: UInt32? {
        if let explicit = mediaKeyType { return explicit }
        guard modifiers == 0 else { return nil }   // 带修饰键的组合不接管裸特殊键
        // 先按顶排键归一到标准 keyCode，再查 NX_KEYTYPE —— 这样存的不管是
        // 标准码（120）还是媒体模式码（144），都能落到同一颗「亮度 +」上。
        let norm = keyCode <= UInt32(UInt16.max)
            ? UInt32(KeyCodes.normalizedTopRowKey(UInt16(keyCode))) : keyCode
        return MediaKey.virtualKeyToKeyType[Int(norm)].map(UInt32.init)
    }

    var displayString: String {
        if let keyType = mediaKeyTypeResolved {
            let label = MediaKey.label(for: Int(keyType))
            // 两个名字都要写出来。**同一颗物理键位**（F1/F2/F5–F12）有两条事件通道：
            //   · 内置键盘「媒体键模式」下（本机默认）不按 fn → NX_SYSDEFINED，名字是「亮度 +」；
            //   · 按住 fn，或换成普通外接键盘（如游戏键盘）→ 普通 keyDown，名字就是「F2」。
            // 只写「亮度 +」会让外接键盘的用户以为设置跑偏了（实测反馈）——他按的明
            // 明是键盘上印着 F2 的那颗键。写成「F2 · 亮度 +」两边都对得上。
            if keyCode <= UInt32(UInt16.max), KeyCodes.isTopRowKey(UInt16(keyCode)) {
                return "\(KeyCodes.name(for: keyCode)) · \(label)"
            }
            return label
        }
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
        // 顶排键先归一到标准那套 keyCode，两种键盘模式显示同一个名字。
        let code = keyCode <= UInt32(UInt16.max)
            ? Int(normalizedTopRowKey(UInt16(keyCode))) : Int(keyCode)
        switch code {
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_F13: return "F13"; case kVK_F14: return "F14"; case kVK_F15: return "F15"
        case kVK_F16: return "F16"; case kVK_F17: return "F17"; case kVK_F18: return "F18"
        case kVK_F19: return "F19"; case kVK_F20: return "F20"
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

extension KeyCodes {
    /// 裸功能键的 keyCode 集合（不带修饰键也能当快捷键）。
    ///
    /// ⚠️ **千万别写成 `kVK_F1...kVK_F12` 的区间判断**：F 键在 keyCode 空间里
    /// 根本不是连续的 —— F1 = 122、F12 = 111，`>= 122 && <= 111` 是个**空区间**，
    /// 永远不成立。曾经就因为这个，录制器把「不带修饰键的 F 键」全部静默丢掉，
    /// 表现成「只能识别 ⌘/⌃/⌥+字母，按 F2、F3 毫无反应」。
    static let functionKeyCodes: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4),
        UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
        UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16),
        UInt16(kVK_F17), UInt16(kVK_F18), UInt16(kVK_F19), UInt16(kVK_F20),
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    /// 顶排键在「**媒体键模式**」下发的 keyCode —— 和标准模式那套完全不是一回事。
    ///
    /// macOS 给同一颗物理键准备了**两套** keyCode，用哪套取决于键盘当前是
    /// 「标准功能键模式」还是「媒体键模式」（Apple 笔记本默认是后者）：
    ///
    /// | 键 | 标准模式 | 媒体键模式 |
    /// |---|---|---|
    /// | F1 亮度− | 122 | 145 |
    /// | F2 亮度+ | 120 | 144 |
    /// | **F3 调度中心** | 99 | **160** |
    /// | **F4 启动台** | 118 | **131** |
    /// | F5 背光− | 96 | 176 |
    /// | F6 背光+ | 97 | 177 |
    /// | F7–F12 | 98/100/101/109/103/111 | 180/179/178/173/174/175 |
    ///
    /// 表的方向：媒体模式 keyCode → 该键在标准模式下的 keyCode。
    ///
    /// ⚠️ **这张表不可尽信，保留只为兼容"另一套 keyCode 的键盘"。**
    ///
    /// 2026-09-25 实测更正：本机（MacBook 内置键盘，媒体键模式）按 **F3/F4 根本不发
    /// keyDown**（HID 层 tap 里一条 96+ 的 keyDown 都没有），它们是以
    /// **NX_SYSDEFINED（subtype 8）** 进来的，keyType = **19 / 20** —— 见
    /// `MediaKey.label`。当初以为 F3/F4 是 keyDown 160/131，据此做的"归一"推理
    /// 是错的；那张 160/131 的对照表来自第三方 crate，与本机行为对不上。
    /// 「事件没送到 tap」的错觉就是这么来的：其实送到了，只是走的是媒体键那条路。
    static let mediaModeKeyCodes: [UInt16: UInt16] = [
        145: UInt16(kVK_F1), 144: UInt16(kVK_F2),
        160: UInt16(kVK_F3), 131: UInt16(kVK_F4),
        176: UInt16(kVK_F5), 177: UInt16(kVK_F6),
        180: UInt16(kVK_F7), 179: UInt16(kVK_F8), 178: UInt16(kVK_F9),
        173: UInt16(kVK_F10), 174: UInt16(kVK_F11), 175: UInt16(kVK_F12),
    ]

    /// 顶排键一律归一到**标准模式**那套 keyCode —— 这样同一个绑定在两种键盘模式下
    /// 都成立（媒体模式按 F3 报 160，归一成 99，照样命中）。
    static func normalizedTopRowKey(_ keyCode: UInt16) -> UInt16 {
        mediaModeKeyCodes[keyCode] ?? keyCode
    }

    /// 是不是顶排功能键 —— 两套 keyCode 都算。
    static func isTopRowKey(_ keyCode: UInt16) -> Bool {
        functionKeyCodes.contains(keyCode) || mediaModeKeyCodes[keyCode] != nil
    }
}
