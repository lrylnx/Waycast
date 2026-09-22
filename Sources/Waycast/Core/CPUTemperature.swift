import Cocoa
import IOKit
import Darwin

/// 状态栏「CPU 温度」图标。
///
/// ## 通道（已实测）
/// Apple Silicon 上 `AppleSMC` 已经没有可用的 CPU 温度键（老 Intel 时代的
/// `TC0P` 之类整批消失），真实温度在 IOHID 的 AppleVendor 温度传感器里，
/// 用 IOHIDEventSystemClient 枚举、`kIOHIDEventTypeTemperature` 取值。
///
/// 实测（macOS 26 / arm64，本机）：
///  - 共 63 个温度服务 / 28 个唯一名称：`PMU tdie0`–`PMU tdie10`（CPU 核心）、
///    `PMU TP*s`/`TP*g`（簇）、`PMU tdev1`–`tdev8`（板级）、`NAND CH0 temp`（SSD）、
///    `gas gauge battery`（电池）、`PMU tcal`（校准参考）。
///  - 压满 CPU 35 秒后 `PMU tdie*` 整体升 3.7–4.2°C，确认它们就是核心温度。
///  - `PMU tcal` 恒定 51.85°C，是校准值不是真实温度，必须排除。
///  - **不需要 root，也不需要任何新权限**（纯用户态 IOKit 枚举）。
///
/// ## 私有 API 的兜底
/// `IOHIDEventSystemClient*` 是 IOKit 导出的私有符号。这里用 dlsym 动态解析
/// 而不是 `@_silgen_name` 硬链接 —— 万一将来某个 macOS 把它删了，应用照常启动，
/// 只是这个图标显示「—°C」，而不是整个 App 起不来。
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
    private let api = HIDTemperatureAPI.shared

    /// 必须持有客户端：服务引用由客户端持有，客户端一释放，
    /// 之前拿到的 service 指针全部失效（会直接崩在 release 上）。
    private var client: CFTypeRef?
    private var serviceArray: CFArray?
    private var sensors: [CFTypeRef] = []
    private var lastEnumeration = Date.distantPast

    private(set) var latest: Double?
    private var didLogUnavailable = false

    /// 是否可用（找不到私有符号时为 false，图标显示「—°C」）。
    var isSupported: Bool { api.isAvailable }

    private static let sensorMatching: [String: Any] = [
        "PrimaryUsagePage": 0xff00,   // kHIDPage_AppleVendor
        "PrimaryUsage": 5             // kHIDUsage_AppleVendor_TemperatureSensor
    ]
    private static let temperatureEventType: Int64 = 15           // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)         // kIOHIDEventFieldBase(...)

    /// 返回当前最热的 CPU 核心温度（°C）。读不到返回 nil。
    func sample() -> Double? {
        guard api.isAvailable else {
            if !didLogUnavailable {
                didLogUnavailable = true
                NSLog("[Waycast] CPU 温度不可用：IOHID 温度接口未找到")
            }
            latest = nil
            return nil
        }
        if client == nil { openClient() }
        guard client != nil else { latest = nil; return nil }

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
