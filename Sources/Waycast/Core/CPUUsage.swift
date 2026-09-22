import Darwin
import Foundation

/// CPU 总体占用率采样 —— `host_statistics` + `HOST_CPU_LOAD_INFO`。
///
/// 内核按四种状态累加 CPU tick（user / system / idle / nice），两次采样求增量
/// 就能算出这一段时间的占用率。**和 `top` 同源**，但只读一份全局计数，
/// 不遍历进程（遍历要 root，而且贵几个数量级）。
///
/// 首次采样只建立基线：没有"上一拍"可比，算不出占用率，返回 nil。
/// 所以图标启动后的第一帧显示 `—%`，1 秒后变成真值。
final class CPUUsageSampler {
    /// 菜单与图标共用一份基线 —— 图标每秒采一次，菜单打开时踩一脚就能拿到真值，
    /// 不必自己再等一拍。（和 `NetworkSpeedSampler.shared` 同样的理由。）
    static let shared = CPUUsageSampler()

    /// 指数滑动平均系数。
    ///
    /// 1 秒窗口的原始占用率跳得很厉害（实测空闲时也会在 0 → 12 → 4 之间乱蹦），
    /// 直接显示看着像故障。取 0.5：既跟得上负载变化（约 2 拍收敛到七成），
    /// 又不会一直闪。
    private let smoothing: Double = 0.5

    private var previous: Ticks?
    private var smoothed: Double?
    private(set) var latest: Double?

    /// 上一次真正算出结果的时刻。
    private var lastComputedAt: Date?

    /// 读数是否"新鲜"。
    ///
    /// 占用率是**增量**量：只有图标在跑（每秒采一次）时才是 1 秒窗口的值。
    /// 图标没在跑时现采一次，算出来的是「上一次采样到现在」的平均 ——
    /// 跨度可能几小时，直接显示会明显误导。菜单据此决定要不要显示它。
    var isFresh: Bool {
        lastComputedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
    }

    /// 是否已经攒够两拍。没到之前 `sample()` 返回 nil，调用方据此显示 `--%`
    /// 而不是先闪一个假的 0%。
    var hasBaseline: Bool { previous != nil }

    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    /// 返回 0~100 的占用率；基线还没建立（或读数失败）时返回 nil。
    @discardableResult
    func sample() -> Double? {
        guard let now = Self.readTicks() else { return nil }
        // 无论后面怎么提前返回，本拍都要成为下一拍的基线。
        defer { previous = now }
        guard let old = previous else { return nil }

        let busy = Self.delta(now.user, old.user)
            + Self.delta(now.system, old.system)
            + Self.delta(now.nice, old.nice)
        let idle = Self.delta(now.idle, old.idle)
        let total = busy + idle
        // 两拍挨得太近时 tick 可能一个都没走（Timer 会合帧、也会被负载推迟），
        // 这时**沿用上一次的值**：返回 nil 会把图标闪成 `--%` 占位符，
        // 而实际上我们上一秒刚拿到过好读数。
        guard total > 0 else { return smoothed }

        let raw = min(max(busy / total * 100.0, 0), 100)
        let value = smoothed.map { $0 * (1 - smoothing) + raw * smoothing } ?? raw
        smoothed = value
        latest = value
        lastComputedAt = Date()
        return value
    }

    /// tick 计数器会回绕（UInt32），新值比旧值小时按 2³² 补偿。
    /// 不给它做补偿的话，回绕那一拍会算出一个荒谬的占用率。
    private static func delta(_ new: UInt32, _ old: UInt32) -> Double {
        new >= old ? Double(new - old) : Double(new) + (4_294_967_296.0 - Double(old))
    }

    private static func readTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks 按 CPU_STATE_USER / SYSTEM / IDLE / NICE 的顺序排列，
        // 元素本身就是 natural_t（UInt32）—— 不用再做位重解释。
        return Ticks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3)
    }
}
