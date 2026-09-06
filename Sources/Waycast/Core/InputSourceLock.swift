import Cocoa
import Carbon

/// 极简「锁定输入法」：把当前输入法钉住，一旦被切走（用户热键、切换 App、
/// 系统自动切换等）立刻自动切回。参考 LockIME 的 LockEngine，只保留锁定
/// 所需的最小实现：读取/选择输入源 + 监听变化 + 偏离即回正。
///
/// 线程安全：状态用 stateLock 保护；分布式通知在主线程 runloop 投递，
/// UI 回调统一切回主线程。
final class InputSourceLock {
    static let shared = InputSourceLock()

    private let stateLock = NSLock()
    private var _isLocked = false
    private var _targetID: String?
    private var registered = false

    /// 锁定状态变化时回调（主线程），供 UI 更新勾选。
    var onChange: (() -> Void)?

    private init() {}

    var isLocked: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isLocked
    }

    func toggle() { isLocked ? disengage() : engage() }

    /// 锁定：记录当前输入法为目标并开始看守。
    func engage() {
        guard let id = Self.currentID() else { return }
        stateLock.lock()
        _isLocked = true
        _targetID = id
        let shouldRegister = !registered
        registered = true
        stateLock.unlock()
        if shouldRegister { registerObserver() }
        DispatchQueue.main.async { self.onChange?() }
    }

    /// 解锁：停止看守，不再干预输入法。
    func disengage() {
        stateLock.lock()
        _isLocked = false
        _targetID = nil
        let shouldRemove = registered
        registered = false
        stateLock.unlock()
        if shouldRemove {
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDistributedCenter(),
                Unmanaged.passUnretained(self).toOpaque())
        }
        DispatchQueue.main.async { self.onChange?() }
    }

    /// 输入源变化通知回调：偏离目标则切回。
    fileprivate func sourceChanged() {
        stateLock.lock()
        let locked = _isLocked
        let target = _targetID
        stateLock.unlock()
        guard locked, let target else { return }
        guard Self.currentID() != target else { return }
        Self.select(target)
        // CJKV 输入法偶尔忽略后台 TISSelectInputSource（返回 noErr 但没生效）。
        // 仅在读回确认没切过去时，延迟重试一次，避免与用户抢键盘。
        if Self.currentID() != target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.stateLock.lock()
                let stillLocked = self._isLocked, sameTarget = (self._targetID == target)
                self.stateLock.unlock()
                guard stillLocked, sameTarget, Self.currentID() != target else { return }
                Self.select(target)
            }
        }
    }

    // MARK: - Text Input Services (Carbon)

    static func currentID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(src, kTISPropertyInputSourceID)
    }

    static func select(_ id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let arr = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let src = arr.first else { return }
        _ = TISSelectInputSource(src)
    }

    private static func string(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    // MARK: - Distributed notification observer

    private func registerObserver() {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            ptr,
            { _, obs, _, _, _ in
                guard let obs else { return }
                let inst = Unmanaged<InputSourceLock>.fromOpaque(obs).takeUnretainedValue()
                inst.sourceChanged()
            },
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )
    }
}
