import Cocoa
import Carbon.HIToolbox
import CoreGraphics
import ApplicationServices

/// 让「顶排那一排键」也能当全局快捷键用。
///
/// 顶排键有两类，形态完全不同：
///   1. **特殊功能键**（亮度 / 音量 / 播放 / 那几颗认不出名字的）走
///      `NX_SYSDEFINED`（CGEventType 14），subtype = 8。这是本机**所有**顶排键
///      的必经之路 —— 2026-09-25 实测日志里，F1/F2/F3/F4/F7/F8/F9/F10/F11/F12
///      全部以 type 14 到达，一条 keyDown 都没有。
///   2. **裸 F 键以 keyDown 进来**：只有键盘处于「标准功能键模式」时才会发生。
///      这条通道要遮住**所有**按键，风险最高 —— 见下面的事故记录，默认关闭。
///
/// ## ⚠️ 事故记录：这里曾经把用户的键盘整体卡死
///
/// 2026-09-25 实测事故（用户原话：「你刚刚改的版本，导致我键盘无法打任何字」，
/// 最后只能用鼠标强退 Waycast）：
///
///   - tap 挂在 `.cghidEventTap` + `.headInsertEventTap` + `.defaultTap`，遮住
///     keyDown / keyUp；
///   - 回调里对**每一个**事件构造 `NSEvent` 并**同步写日志文件**。
///
/// 两者叠加就是灾难：HID 层的 head-insert default tap 处在系统输入链路的**最前端**，
/// 它的回调没返回之前，那颗键不会被任何 App 看到；在回调里做内存分配（NSEvent）
/// 和磁盘 I/O，等于把全系统的键盘按住了。
///
/// 由此定下四条硬规矩，**一条都不能破**：
///   1. **不上 HID 层**。只用 `.cgSessionEventTap`（顶排键的必经之路，够用）。
///   2. tap 回调里**只做整数运算** —— 不建对象、不写文件、不加锁、不碰 AppKit。
///      唯一允许的对象构造是为 type 14 建一次 NSEvent（要读 subtype/data1，
///      CGEvent 没有等价的公开字段），这个在早先版本里一直存在、频率也低。
///   3. 没有要接管的东西 → **一个 tap 都不装**，行为与没有这个功能时一模一样。
///   4. 拆 tap 的顺序：`tapEnable(false)` → 摘 run loop source →
///      **`CFMachPortInvalidate`**。少了最后一步，端口留着没人读，事件会堆在
///      无人消费的 mach port 上 —— 那也是键盘假死的成因之一。
///
/// ## 去重
/// 同一颗物理键可能两条通道各报一次（媒体键通道报 keyType 3，keyDown 通道报
/// 键码 122，说的都是 F1）。按**顶排物理位置**归一，120ms 内只触发一次。
///
/// ## 边界
///   - 只接管**裸按键**（不带 ⌘⌃⌥⇧）；带修饰键的组合交给 Carbon 就够。
///   - 命中就**成对吞掉**（按下 + 抬起）；没绑定的原样放行（不绑亮度键，它照常调亮度）。
///   - 动作一律异步派到主队列，绝不在回调里同步跑重活（截图抓帧 25–110ms）。
final class MediaKeyBindings {
    static let shared = MediaKeyBindings()

    private init() {}

    typealias Action = @MainActor () -> Void

    /// 被 tap 拦下来的一次按键（录制时用）。
    enum Captured {
        /// 特殊功能键：值 = NX_KEYTYPE。
        case special(keyType: Int)
        /// 功能键：值 = 虚拟键码（F1–F20）。
        case function(keyCode: UInt32)
    }

    /// keyType → 要执行的动作（特殊功能键通道）。由 `AppDelegate.registerHotkeys()` 装配。
    private var mediaActions: [Int: Action] = [:]

    /// keyCode → 要执行的动作（裸功能键通道）。
    private var functionActions: [UInt32: Action] = [:]

    /// 录制模式：设置窗口正在等一个新快捷键。非 nil 时相关按键都被吞掉，
    /// 免得录制过程中系统顺手把亮度调了、把调度中心弹出来。
    private var recordingHandler: ((Captured, Bool) -> Void)?

    /// 是否接管「以 keyDown 进来的裸 F 键」。**默认关**（见文件头事故记录）。
    /// 只有键盘处于「标准功能键模式」时才需要 —— 那时顶排键不报 type 14。
    private var keyDownChannelWanted = false

    /// 已经吞掉按下的键 —— 它们对应的抬起也要吞，否则系统会收到一个孤立的 keyUp。
    private var swallowedKeyTypes: Set<Int> = []
    private var swallowedKeyCodes: Set<UInt32> = []

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 当前这个 tap 的 mask 里有没有 keyDown/keyUp —— 开关变了要重装。
    private var installedKeyDownChannel = false

    /// 同一颗物理键的两种事件形态共用的去重账本（键 = 顶排物理位置）。
    private var lastFired: [UInt32: TimeInterval] = [:]
    private static let dedupeWindow: TimeInterval = 0.12

    /// tap 装上了没有 —— 装上了这类绑定才可能起作用。
    var isInstalled: Bool { tap != nil }

    /// keyDown 通道是否真的在生效。设置界面用它提示「为什么按了没反应」。
    var keyDownChannelActive: Bool { tap != nil && installedKeyDownChannel }

    /// 当前被接管的 keyType（设置界面用来给用户提示）。
    private(set) var activeKeyTypes: Set<Int> = []

    // MARK: - 装配

    func update(mediaActions newMediaActions: [Int: Action],
                functionActions newFunctionActions: [UInt32: Action]) {
        mediaActions = newMediaActions
        functionActions = newFunctionActions
        activeKeyTypes = Set(newMediaActions.keys)
        syncInstallation()
    }

    /// 开关「裸 F 键（keyDown 通道）」。打开会遮住所有按键，只在该键盘上
    /// 顶排键压根不报 type 14 时才值得开 —— 见文件头事故记录。
    func setKeyDownChannel(_ on: Bool) {
        guard keyDownChannelWanted != on else { return }
        keyDownChannelWanted = on
        syncInstallation()
    }

    /// 设置界面开始录制时调用。录制期间会安装 tap（即使当前没有任何绑定），
    /// 这样才能"按下 F3 也录得到"。
    func beginRecording(_ handler: @escaping (Captured, Bool) -> Void) {
        recordingHandler = handler
        syncInstallation()
    }

    func endRecording() {
        recordingHandler = nil
        syncInstallation()
    }

    private func syncInstallation() {
        let wantKeyDown = keyDownChannelWanted
            && (!functionActions.isEmpty || recordingHandler != nil)
        let needed = !mediaActions.isEmpty || recordingHandler != nil || wantKeyDown
        // 已经装着且 mask 正确 → 什么都不做（**不要**为了省事反复拆装 tap）。
        if self.tap != nil {
            if needed && installedKeyDownChannel == wantKeyDown { return }
            teardown()
        }
        guard needed else { return }
        install(keyDownChannel: wantKeyDown)
    }

    // MARK: - tap 生命周期

    /// NX_SYSDEFINED —— CGEventType 没有给这个 case 起 Swift 名，只能按原始值用。
    private static let systemDefinedRaw: UInt32 = 14

    private func install(keyDownChannel: Bool) {
        var mask: CGEventMask = 1 << Self.systemDefinedRaw
        if keyDownChannel {
            mask |= 1 << CGEventType.keyDown.rawValue
            mask |= 1 << CGEventType.keyUp.rawValue
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: { _, type, event, refcon in
                                                 guard let refcon else {
                                                     return Unmanaged.passUnretained(event)
                                                 }
                                                 let me = Unmanaged<MediaKeyBindings>
                                                     .fromOpaque(refcon).takeUnretainedValue()
                                                 return me.handle(type: type, event: event)
                                             },
                                             userInfo: selfPtr) else {
            NSLog("[Waycast] 顶排键监听装不上（需要「辅助功能」权限）——"
                  + "亮度/音量/F 键暂时不能当快捷键，其他键不受影响。")
            return
        }

        tap = newTap
        installedKeyDownChannel = keyDownChannel
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    private func teardown() {
        // 顺序有讲究：先摘 source 会让端口暂时没人读，所以先停 tap、再摘、最后销毁。
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        installedKeyDownChannel = false
        swallowedKeyTypes.removeAll()
        swallowedKeyCodes.removeAll()
        lastFired.removeAll()
    }

    // MARK: - 事件处理（主线程）

    /// ⚠️ 这个函数跑在**系统输入链路**上：进来的每一颗键都要等它返回。
    /// 只允许做整数比较和字典查找 —— 不建对象、不写文件、不加锁。
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        // 系统把 tap 关掉（回调超时、或密码框的输入保护区）—— 不重新打开的话
        // 之后这类键就再也收不到了。重开只是恢复监听，与键本身是否放行无关。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough
        }

        if type.rawValue == Self.systemDefinedRaw {
            guard let press = MediaKey.press(from: event) else { return passthrough }
            return handleSpecial(press, passthrough: passthrough)
        }
        if type == .keyDown || type == .keyUp {
            guard installedKeyDownChannel else { return passthrough }
            return handleFunctionKey(type: type, event: event, passthrough: passthrough)
        }
        return passthrough
    }

    /// 特殊功能键（亮度 / 音量 / 播放…）。
    private func handleSpecial(_ press: MediaKey.Press,
                               passthrough: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        if let recordingHandler {
            recordingHandler(.special(keyType: press.keyType), press.isDown)
            return nil          // 录制期间吞掉
        }

        guard let action = mediaActions[press.keyType] else {
            return passthrough   // 没被绑定 → 放行（亮度照常）
        }

        if press.isDown {
            swallowedKeyTypes.insert(press.keyType)
            if shouldFire(position: Self.position(ofKeyType: press.keyType)) { fire(action) }
        } else if swallowedKeyTypes.remove(press.keyType) == nil {
            return passthrough
        }
        return nil
    }

    /// 裸功能键（F1–F20）。只接管裸按键；带修饰键的组合放行给 Carbon。
    private func handleFunctionKey(type: CGEventType, event: CGEvent,
                                   passthrough: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        let raw = event.getIntegerValueField(.keyboardEventKeycode)
        guard raw >= 0, raw <= Int(UInt16.max) else { return passthrough }
        let keyCode = UInt32(raw)
        // 顶排键有两套 keyCode（标准模式 / 媒体键模式），**先归一再判断和查找**。
        let position = UInt32(KeyCodes.normalizedTopRowKey(UInt16(raw)))
        guard KeyCodes.isTopRowKey(UInt16(raw)) else {
            return passthrough   // 普通字母 / 数字键：与我们无关，立刻放行
        }
        // fn（maskSecondaryFn）不算修饰键 —— 按住 fn 按功能键是最常见的用法。
        let realModifiers = event.flags.intersection([.maskCommand, .maskShift,
                                                      .maskAlternate, .maskControl])
        guard realModifiers.isEmpty else { return passthrough }

        let isDown = (type == .keyDown)
        if isDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil          // 长按产生的重复：吞掉，但不重复触发
        }

        if let recordingHandler {
            // 报到录制器里的是**归一后**的 keyCode，落盘的绑定就跟键盘模式无关了。
            recordingHandler(.function(keyCode: position), isDown)
            return nil
        }

        guard let action = functionActions[position] ?? functionActions[keyCode] else {
            return passthrough
        }

        if isDown {
            swallowedKeyCodes.insert(keyCode)      // 抬起要按**原样**的 keyCode 配对
            if shouldFire(position: position) { fire(action) }
        } else if swallowedKeyCodes.remove(keyCode) == nil {
            return passthrough
        }
        return nil
    }

    /// 把 NX_KEYTYPE 折成它在顶排的**物理位置**（虚拟键码），好和 keyDown 通道对齐。
    /// 表外的 keyType（键盘代次不同会冒出来）给一个不会撞车的偏移值。
    private static func position(ofKeyType keyType: Int) -> UInt32 {
        if let vk = MediaKey.keyTypeToVirtualKey[keyType] { return UInt32(vk) }
        return UInt32(10_000 + keyType)
    }

    /// 同一颗物理键的两条通道去重。
    ///
    /// 例：F1 在媒体键模式下是 NX_SYSDEFINED（keyType 3），键盘切到标准功能键模式
    /// 后是 keyDown 122 —— 两件事说的是同一颗键，只该触发一次。
    private func shouldFire(position: UInt32) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastFired[position], now - last < Self.dedupeWindow { return false }
        lastFired[position] = now
        return true
    }

    /// 动作一律**异步**派发到主队列。
    ///
    /// tap 回调在系统输入热路径上，在里面同步跑重活会把整个系统的键鼠一起卡住
    /// —— 截图光抓帧就要 25–110ms，绝对不能同步等。多一次主队列 hop 换系统输入
    /// 的安全，值。
    private func fire(_ action: Action?) {
        guard let action else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }
}
