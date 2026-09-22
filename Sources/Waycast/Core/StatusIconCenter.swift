import Cocoa

/// 状态栏图标总控。
///
/// 状态栏只有一个位置，所以「默认闪电 / 内存水位 / 网速 / CPU 温度」四选一，
/// 由这里做互斥调度：切换时先把所有 provider 的定时器停掉，再启动目标那一个。
/// 没有启用的 provider 定时器是 nil，不采样、不重绘 —— 关闭即零开销。
final class StatusIconCenter {
    static let shared = StatusIconCenter()

    /// 往上抛图像；nil = 恢复默认闪电图标。
    var onImageChange: ((NSImage?) -> Void)?
    /// 模式变化回调（供菜单勾选同步）。
    var onModeChange: (() -> Void)?

    /// 当前模式。
    ///
    /// 必须在**构造时**就从设置里读出来，而不是等 `start()`：
    /// AppDelegate 是"先建菜单、后调 start()"的顺序，如果这里留成 .bolt，
    /// 菜单第一次构建出来时勾选标记会错误地停在「默认图标」上。
    private(set) var mode: StatusIconMode = AppSettings.shared.statusIconMode

    private let memoryMonitor = WaterlineMemoryMonitor()
    private let temperatureSampler = CPUTemperatureSampler()

    private init() {}

    /// 由 AppDelegate 在状态栏按钮就绪后调用一次。
    func start() {
        MemoryWaterline.shared.onIconUpdate = { [weak self] image in self?.onImageChange?(image) }
        NetworkSpeedIcon.shared.onIconUpdate = { [weak self] image in self?.onImageChange?(image) }
        CPUTemperatureIcon.shared.onIconUpdate = { [weak self] image in self?.onImageChange?(image) }

        mode = AppSettings.shared.statusIconMode
        apply()
    }

    func select(_ newMode: StatusIconMode) {
        guard newMode != mode else { return }
        mode = newMode
        AppSettings.shared.statusIconMode = newMode
        apply()
        onModeChange?()
    }

    /// 点当前已选中的那个 = 回到默认闪电图标。
    /// （和原来「内存水位图标」的交互保持一致：再点一次就切回去。）
    func toggle(_ target: StatusIconMode) {
        select(target == mode ? .bolt : target)
    }

    private func apply() {
        // stop() 不主动抛 nil，避免切换过程中闪一下默认图标。
        MemoryWaterline.shared.stop()
        NetworkSpeedIcon.shared.stop()
        CPUTemperatureIcon.shared.stop()

        switch mode {
        case .bolt:    onImageChange?(nil)
        case .memory:  MemoryWaterline.shared.start()
        case .network: NetworkSpeedIcon.shared.start()
        case .cpuTemp: CPUTemperatureIcon.shared.start()
        }
    }

    // MARK: - 菜单里的实时读数

    /// 菜单打开时踩一脚采样器：网速要靠前后两拍才能算出速率，
    /// 这样菜单里的读数能在 1 秒内变成真值。
    ///
    /// **CPU 占用率刻意不在这里预热**：预热不会让它的值变准，只会把
    /// 「上一次采样到现在」的长窗口平均冒充成即时值（见 `isFresh`）。
    func primeMenuReadings() {
        _ = NetworkSpeedSampler.shared.sample()
    }

    /// 某个模式当前的读数文本；拿不到就返回 nil（菜单只显示模式名）。
    func reading(for target: StatusIconMode) -> String? {
        switch target {
        case .bolt:
            return nil
        case .memory:
            let sample = memoryMonitor.sample()
            return sample.total > 0 ? String(format: "%.0f%%", sample.usagePercent) : nil
        case .network:
            // 速率必须现采：读数每显示一次就采一次，凑出"上一拍 → 现在"的间隔。
            // 只在打开菜单时踩一脚是不够的 —— 那样恒速之后再也没有新样本。
            let sample = NetworkSpeedSampler.shared.sample()
            guard NetworkSpeedSampler.shared.hasBaseline else { return nil }
            return NetReadings.network(sample)
        case .cpuTemp:
            // 图标上是「占用率 / 温度」两行，菜单里写成一行完整读数。
            //
            // 占用率只在**图标正在跑**（每秒采一次、读数是 1 秒窗口）时才显示；
            // 否则现采一次算出来的是「上次采样到现在」的平均，跨度可能几小时，
            // 显示它反而误导 —— 这时就只报温度。
            let usage = CPUUsageSampler.shared.isFresh ? CPUUsageSampler.shared.sample() : nil
            let temperature = temperatureSampler.sample()
                .map { "\(Int($0.rounded()))°C" }
            switch (temperature, usage) {
            case let (t?, u?):  return "\(t) · \(Int(u.rounded()))%"
            case let (t?, nil): return t
            case let (nil, u?): return "占用 \(Int(u.rounded()))%"
            case (nil, nil):    return nil
            }
        }
    }
}
