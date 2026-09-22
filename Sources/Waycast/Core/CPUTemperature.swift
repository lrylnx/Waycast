import Cocoa
import IOKit
import Darwin

/// 状态栏「CPU 温度」图标。
///
/// ## 通道（实测修正）
///
/// **首选 SMC 的 `TC[0-9]*`（CPU 核心），IOHID 的 `PMU tdie*` 降级为兜底。**
///
/// 早先版本认为「Apple Silicon 上 AppleSMC 已经没有可用的 CPU 温度键」——**那是错的**。
/// AppleSMC 能正常打开，只是键名从 Intel 的 `TC0P` 换成了 `TC10`–`TC53`。
/// 而 IOHID 的 `PMU tdie*` 虽然读得到、刷新率也有 3.5Hz，但对负载几乎无响应：
///
/// | 通道 | 空闲 | 10 核满载 60s | 涨幅 |
/// |---|---|---|---|
/// | IOHID `PMU tdie*`（旧） | 46.5°C | 47.9°C | +1.4°C |
/// | SMC `TC[0-9]*`（新） | 50.2°C | 61.9°C | **+11.6°C** |
///
/// `PMU tdie*` 那 11 个「核心」读数彼此差不到 0.6°C —— 真实多核 CPU 不可能这么齐，
/// 说明它是 **SoC 级平均温度**，多核一摊薄就对负载失去响应。用户反馈的
/// 「跑满大负荷才慢吞吞升 1 度」就是它造成的。
///
/// 两条通道都**不需要 root，也不需要任何新权限**（纯用户态 IOKit）。
///
/// ## IOHID 兜底的注意事项
///  - `PMU tcal` 恒定 51.85°C，是校准值不是真实温度，**必须排除**，否则取 max
///    会被这个假值永久锁死。
///  - `PMU tdev4`/`tdev5` 在部分机型上明显偏低（本机 36°C，其余 tdev 45°C+），
///    混进 max 会拉低读数，所以只取 `PMU tdie*`。
final class CPUTemperatureIcon {
    static let shared = CPUTemperatureIcon()

    /// 图标更新回调（主线程）；nil 表示恢复默认图标。
    var onIconUpdate: ((NSImage?) -> Void)?

    private let sampler = CPUTemperatureSampler()
    private var timer: Timer?

    private init() {}

    func start() {
        render(sampler.sample())
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.render(self.sampler.sample())
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 温度分档：正常温度不上色（交给系统按菜单栏明暗自动取色），
    /// 偏热 / 过热才染色 —— 这样既不会在浅色菜单栏上出现白字糊掉，也保留了报警感。
    ///
    /// 传进来的是**显示用的整数值**：74.9 显示成 "75°C"，颜色阈值就必须按 75 判，
    /// 否则会出现"显示 75°C 却不是橙色"的割裂。
    static func severityColor(_ celsius: Double) -> NSColor? {
        if celsius >= 90 {
            return NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1.0)   // 红
        }
        if celsius >= 75 {
            return NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.04, alpha: 1.0)   // 橙
        }
        return nil
    }

    /// 恒为 5 字符（" 42°C" / "105°C" / "  —°C"），配合 SF Mono 保证宽度不抖。
    static func displayText(_ celsius: Double?) -> String {
        let number = sanitized(celsius).map { String(format: "%3.0f", $0.rounded()) } ?? "  —"
        return number + "°C"
    }

    private static func sanitized(_ celsius: Double?) -> Double? {
        guard let celsius, celsius.isFinite else { return nil }
        return celsius
    }

    private func render(_ celsius: Double?) {
        let value = Self.sanitized(celsius)
        let text = Self.displayText(value)
        let image: NSImage
        if let value, let color = Self.severityColor(value.rounded()) {
            image = StatusTextIcon.render(text, color: color, template: false)
        } else {
            image = StatusTextIcon.render(text, template: true)
        }
        image.accessibilityDescription = value.map { "CPU 温度 \(Int($0.rounded())) 摄氏度" }
            ?? "CPU 温度不可用"
        onIconUpdate?(image)
    }
}

// MARK: - 采样

final class CPUTemperatureSampler {

    /// 读数来自哪条通道。SMC 优先，IOHID 是兜底。
    enum Source {
        case smc          // AppleSMC 的 TC[0-9]*（CPU 核心，对负载敏感）
        case ioHID        // IOHID 的 PMU tdie*（SoC 平均温度，反应迟钝）
        case unavailable
    }

    private let api = HIDTemperatureAPI.shared
    private let smc = SMCTemperatureReader()

    /// 必须持有客户端：服务引用由客户端持有，客户端一释放，
    /// 之前拿到的 service 指针全部失效（会直接崩在 release 上）。
    private var client: CFTypeRef?
    private var serviceArray: CFArray?
    private var sensors: [CFTypeRef] = []
    private var lastEnumeration = Date.distantPast

    private(set) var latest: Double?
    private(set) var source: Source = .unavailable
    private var didLogUnavailable = false

    /// 是否可用（两条通道都拿不到时为 false，图标显示「—°C」）。
    var isSupported: Bool { smc.isAvailable || api.isAvailable }

    private static let sensorMatching: [String: Any] = [
        "PrimaryUsagePage": 0xff00,   // kHIDPage_AppleVendor
        "PrimaryUsage": 5             // kHIDUsage_AppleVendor_TemperatureSensor
    ]
    private static let temperatureEventType: Int64 = 15           // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)         // kIOHIDEventFieldBase(...)

    /// 返回当前最热的 CPU 核心温度（°C）。读不到返回 nil。
    func sample() -> Double? {
        // 1) 首选 AppleSMC 的 CPU 核心温度 —— 这条才对负载敏感。
        if smc.open(), let value = smc.readCoreMaximum(), value > 0 {
            latest = value
            source = .smc
            return value
        }

        // 2) 退回 IOHID。它是 SoC 级平均温度、反应迟钝，但能给出趋势，
        //    总好过显示「—°C」。
        guard api.isAvailable else {
            if !didLogUnavailable {
                didLogUnavailable = true
                NSLog("[Waycast] CPU 温度不可用：SMC 与 IOHID 两条通道都没拿到")
            }
            latest = nil
            source = .unavailable
            return nil
        }
        if client == nil { openClient() }
        guard client != nil else {
            latest = nil
            source = .unavailable
            return nil
        }

        // 每 30 秒重新枚举一次：休眠唤醒后服务可能失效，重建即可自愈。
        if sensors.isEmpty || Date().timeIntervalSince(lastEnumeration) > 30 {
            enumerateSensors()
        }

        var hottest: Double = 0
        for sensor in sensors {
            guard let copyEvent = api.copyEvent,
                  let rawEvent = copyEvent(sensor, Self.temperatureEventType, 0, 0) else { continue }
            let event = rawEvent.takeRetainedValue()
            let value = api.getFloatValue?(event, Self.temperatureField) ?? 0
            if value > 0 { hottest = max(hottest, value) }
        }

        let result = hottest > 0 ? hottest : nil
        latest = result
        source = result == nil ? .unavailable : .ioHID
        return result
    }

    private func openClient() {
        guard let create = api.create else { return }
        client = create(kCFAllocatorDefault)?.takeRetainedValue()
    }

    private func enumerateSensors() {
        lastEnumeration = Date()
        sensors = []
        serviceArray = nil

        guard let client,
              let setMatching = api.setMatching,
              let copyServices = api.copyServices,
              let copyProperty = api.copyProperty else { return }

        _ = setMatching(client, Self.sensorMatching as CFDictionary)
        guard let array = copyServices(client)?.takeRetainedValue() else { return }
        serviceArray = array

        for index in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let service = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard let rawName = copyProperty(service, "Product" as CFString) else { continue }
            let name = rawName.takeRetainedValue() as String
            // 只要 CPU 核心的 die 温度传感器；tcal 是校准值，恒定不变，排除。
            guard name.hasPrefix("PMU tdie") else { continue }
            sensors.append(service)
        }
    }
}

// MARK: - 私有符号绑定（dlsym，缺符号则优雅降级）

private final class HIDTemperatureAPI {
    static let shared = HIDTemperatureAPI()

    typealias CreateFn       = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias SetMatchingFn  = @convention(c) (CFTypeRef, CFDictionary?) -> Int32
    typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFString>?
    typealias CopyEventFn    = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias GetFloatFn     = @convention(c) (CFTypeRef, Int32) -> Double

    let create: CreateFn?
    let setMatching: SetMatchingFn?
    let copyServices: CopyServicesFn?
    let copyProperty: CopyPropertyFn?
    let copyEvent: CopyEventFn?
    let getFloatValue: GetFloatFn?

    var isAvailable: Bool {
        create != nil && setMatching != nil && copyServices != nil
            && copyProperty != nil && copyEvent != nil && getFloatValue != nil
    }

    private init() {
        // dlsym 不会产生符号引用，链接器可能因此不把 IOKit 载进来；
        // 调一个公开的 IOKit 函数，确保框架一定在全局符号表里。
        _ = IOServiceMatching("IOHIDSystem")

        let handle = dlopen(nil, RTLD_LAZY)
        func resolve<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        create = resolve("IOHIDEventSystemClientCreate", CreateFn.self)
        setMatching = resolve("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
        copyServices = resolve("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyProperty = resolve("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)
        copyEvent = resolve("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloatValue = resolve("IOHIDEventGetFloatValue", GetFloatFn.self)
    }
}
