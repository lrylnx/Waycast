import Cocoa
import Carbon.HIToolbox
import CoreGraphics

/// 顶排的「特殊功能键」（亮度 / 音量 / 播放控制…）在 macOS 上**不是普通按键**：
/// 系统把它们作为 NX_SYSDEFINED（CGEventType = 14）发出来，而不是 keyDown。
///
/// 两个直接后果 —— 也是「F 键按了没反应」的第二层原因：
///   1. `NSEvent` 的 keyDown 监听完全看不到它们；
///   2. Carbon 的 `RegisterEventHotKey` 也抓不到它们（那个 API 只认虚拟键码）。
/// 想把这些键当快捷键用，只能自己开一个 session 级 event tap 去截
/// （见 `MediaKeyBindings`）。
///
/// 常量取自 SDK 的 `IOKit/hidsystem/ev_keymap.h` 与 `IOLLEvent.h`。
enum MediaKey {

    /// NX_KEYTYPE → 它落在顶排的哪个物理位置（虚拟键码）。
    ///
    /// ⚠️ **19 / 20 是实测补进来的，不是从 SDK 抄的。** 本机（MacBook 内置键盘，
    /// 媒体键模式）按 F3 / F4 发出来的就是 `keyType = 19 / 20`，而 SDK 的
    /// `ev_keymap.h` 里 19/20 写的是 FAST / REWIND —— 名字对不上，位置却是真的。
    ///
    /// 为什么非得补这条位置：`position(ofKeyType:)` 要先知道「这颗键在顶排的哪个
    /// 位置」才能和 keyDown 那条通道对齐。缺了它，绑定 F3 只会登记成一条
    /// 「代码 19」的孤立绑定 —— 换一块**走普通 keyDown 的键盘**（或切到标准功能键
    /// 模式）按同一颗键，发出来的是 keyCode 99，跟这条绑定对不上，就"失灵"了。
    static let keyTypeToVirtualKey: [Int: Int] = [
        3:  kVK_F1,   // 亮度 −
        2:  kVK_F2,   // 亮度 +
        19: kVK_F3,   // 调度中心（实测；SDK 头文件里写的 FAST 是错的）
        20: kVK_F4,   // 聚焦（实测；SDK 头文件里写的 REWIND 是错的）
        22: kVK_F5,   // 老 Intel：键盘背光 −｜M 系列新模具：这颗印的是「听写」
        21: kVK_F6,   // 老 Intel：键盘背光 +｜M 系列新模具：这颗印的是「勿扰」
        18: kVK_F7,   // 上一曲
        16: kVK_F8,   // 播放 / 暂停
        17: kVK_F9,   // 下一曲
        7:  kVK_F10,  // 静音
        1:  kVK_F11,  // 音量 −
        0:  kVK_F12,  // 音量 +
    ]

    /// 反查：虚拟键码 → NX_KEYTYPE。
    static let virtualKeyToKeyType: [Int: Int] = Dictionary(
        uniqueKeysWithValues: keyTypeToVirtualKey.map { ($1, $0) })

    /// 给用户看的说明文案。
    /// 19 / 20 见 `keyTypeToVirtualKey` 的注释：本机 F3 / F4 实测就是这两个码。
    ///
    /// ⚠️ 顶排键**按机器代次分两套布局**（2026-09-25 按实物照片更正，别再用一套名字套所有机器）：
    ///   · 老款 Intel MacBook Pro：F1/F2 亮度、F3 调度中心、F4 聚焦、
    ///     **F5/F6 是键盘背光 ±**、F7–F9 上一曲/播放/下一曲、F10–F12 静音/音量。
    ///   · Apple Silicon 新模具：F5 印的是**麦克风（听写）**、F6 印的是**月亮（勿扰）** ——
    ///     早就没有键盘背光这颗键了。
    /// ⇒ 21/22 这两个码只在老机器上等于「背光」，所以下面写成「背光 −/听写」这种双名。
    static let label: [Int: String] = [
        3: "亮度 −", 2: "亮度 +",
        19: "调度中心", 20: "聚焦",
        22: "背光 −/听写", 21: "背光 +/勿扰",
        18: "上一曲", 16: "播放/暂停", 17: "下一曲",
        7: "静音", 1: "音量 −", 0: "音量 +",
    ]

    /// 名字**不再只认表内**：键盘代次不同，顶排键发的 NX_KEYTYPE 也会变。
    /// 实测（2026-09-25，本机 MacBook + 媒体键模式）：F3（调度中心）/ F4（聚焦）
    /// 报的是 **19 / 20**，而 SDK 的 `ev_keymap.h` 里 19/20 写的是 FAST/REWIND ——
    /// 对不上。既然头文件不可尽信，就不能让「名字查不到」变成「功能用不了」：
    /// 表外的 keyType 一律允许绑定，名字先用代码占位。
    static func label(for keyType: Int) -> String {
        label[keyType] ?? "顶排键（代码 \(keyType)）"
    }

    /// 这个 keyType 是否在已知功能表内（设置界面用来提示"名字只是占位"）。
    static func hasKnownName(_ keyType: Int) -> Bool { label[keyType] != nil }

    /// 一次特殊键的按下 / 抬起。
    struct Press {
        let keyType: Int
        let isDown: Bool
    }

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS —— 特殊功能键事件的 subtype。
    private static let auxControlButtons = 8
    /// NX_KEYDOWN / NX_KEYUP（IOLLEvent.h）。
    private static let keyDownState = 0x0A
    private static let keyUpState = 0x0B

    /// 从 NSEvent 里解析；不是特殊功能键则返回 nil。
    static func press(from event: NSEvent) -> Press? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == auxControlButtons else { return nil }

        // data1 = (keyType << 16) | (state << 8) | flags
        let data1 = event.data1
        let keyType = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0x0000_FF00) >> 8
        guard state == keyDownState || state == keyUpState else { return nil }
        return Press(keyType: keyType, isDown: state == keyDownState)
    }

    static func press(from cgEvent: CGEvent) -> Press? {
        guard let ns = NSEvent(cgEvent: cgEvent) else { return nil }
        return press(from: ns)
    }
}
