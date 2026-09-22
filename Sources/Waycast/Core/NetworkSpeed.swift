import Cocoa
import Darwin

/// 状态栏「实时网速」图标 —— 每秒刷新一次上下行速率。
///
/// ## 采样通道（已实测，见下方注释里的实测数据）
/// 走 `sysctl(NET_RT_IFLIST2)` 的 `if_msghdr2`。**不能用 `getifaddrs`**：
/// 它的 `if_data.ifi_ibytes` 是 u_int32_t，直接就截断了。
///
/// ## 两个必须处理的坑
/// 1. **只统计物理网卡**（`en*` / `pdp_ip*`）。开着 VPN 时同一份流量会被
///    `en0` 和 `utunN` 各记一次，把 utun 一起加进来速度直接翻倍。
/// 2. **计数器每 4 GiB 回绕一次**。实测（macOS 26 / arm64）：内核往
///    `ifm_data.ifi_ibytes` 的 64 位字段里**只写低 32 位**，高 32 位恒为 0
///   —— 同一时刻 `netstat -ib` 报 en0 收包 19204539407 字节，这里读到
///    2024669184，两者正好差 4 × 2³²。所以必须按接口单独做回绕补偿。
final class NetworkSpeedIcon {
    static let shared = NetworkSpeedIcon()

    /// 图标更新回调（主线程）；nil 表示恢复默认图标。
    var onIconUpdate: ((NSImage?) -> Void)?

    private let sampler = NetworkSpeedSampler()
    private var timer: Timer?

    private init() {}

    func start() {
        render(sampler.sample())   // 首帧只有计数、没有速率，先画 0
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.render(self.sampler.sample())
        }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 状态栏图标上的文字，**两行**、每行恒为 5 字符（"↑340K" / "↓1.2M"）。
    ///
    /// 单独抽出来是为了让"图标渲染"和"离线校验"走同一条代码路径 ——
    /// 校验脚本里手写字符串副本，就会量到和实际不符的宽度。
    ///
    /// **为什么改成上下两行：** 并排写要 10 个字符 ≈ 70pt，在菜单栏里横着占
    /// 一大截，右边一排图标都被挤走。改成两个 5 字符的短行后宽度只剩 ≈ 36pt，
    /// 和 CPU 温度图标一样宽。代价是高度要占两层：11pt 字体按自然行距排两行
    /// 需要 30pt，超过菜单栏的 22pt，所以渲染侧改成按墨迹裁着堆叠（见
    /// `StatusTextIcon.render`），两层合计 20pt。
    ///
    /// **行序：上行在上、下行在下** —— 箭头朝向要和所在行的位置一致，
    /// 上面那行画 "↑"（上行），下面那行画 "↓"（下行）。
    static func displayText(_ s: NetworkSpeedSample) -> String {
        "↑\(RateFormat.short(s.txBytesPerSec))\n↓\(RateFormat.short(s.rxBytesPerSec))"
    }

    private func render(_ s: NetworkSpeedSample) {
        // template：文字交给系统上色，明暗主题和高亮态都不会出问题。
        let image = StatusTextIcon.render(Self.displayText(s), template: true)
        image.accessibilityDescription = "网速 下行 \(RateFormat.full(s.rxBytesPerSec)) 上行 \(RateFormat.full(s.txBytesPerSec))"
        onIconUpdate?(image)
    }
}

// MARK: - 速率格式化

enum RateFormat {
    /// 恒为 4 字符的速率字段（"  0B" / "512B" / "1.2M" / " 12M"）。
    ///
    /// 定宽是刻意的：图标每秒重绘，宽度一变整排菜单栏图标都会跟着抖。
    /// 配合 SF Mono（11pt 下每字符恒为 6.80pt），整串宽度 = 字符数 × 6.80，恒定。
    static func short(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G"]
        // NaN / ±inf 一律按 0 处理，别让它们顺着比较运算掉进最后一个单位。
        var value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        var index = 0
        // 当前单位放不下 4 字符就换更大的单位（999.6K -> 1.0M）。
        while index < units.count - 1 {
            if let field = field(value, units[index]) { return field }
            value /= 1000
            index += 1
        }
        return field(value, units[units.count - 1]) ?? "999G"
    }

    /// 返回恰好 4 字符的字段；`value` 在该单位下装不进 4 字符时返回 nil。
    private static func field(_ value: Double, _ unit: String) -> String? {
        // 小数值优先带一位小数，读起来更有信息量。
        // 注意 9.96 会被 "%.1f" 进成 "10.0"（4 字符放不下），这时退回整数写法。
        if unit != "B", value < 10 {
            let oneDecimal = String(format: "%.1f", value)
            if oneDecimal.count == 3 { return oneDecimal + unit }
        }
        let rounded = value.rounded()
        guard rounded >= 0, rounded <= 999 else { return nil }
        return pad(String(format: "%.0f", rounded), 3) + unit
    }

    /// 菜单里用的完整写法（不要求定宽）。
    static func full(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: index > 0 && value < 10 ? "%.1f %@" : "%.0f %@", value, units[index])
    }

    static func pad(_ s: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - s.count)) + s
    }
}

// MARK: - 采样

struct NetworkSpeedSample {
    var rxBytesPerSec: Double = 0
    var txBytesPerSec: Double = 0
    static let zero = NetworkSpeedSample()
}

/// 网速采样器。持有上一次的计数器，两次采样之间的差 / 实际间隔 = 速率。
final class NetworkSpeedSampler {
    /// 菜单用它取一份独立读数，避免和图标自己的定时器互相干扰。
    static let shared = NetworkSpeedSampler()

    private var previous: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var previousTime: Date?
    private(set) var latest = NetworkSpeedSample.zero

    /// 是否已经攒够两拍、能算出真实速率。没到之前 `latest` 恒为 0，
    /// 菜单据此决定是显示读数还是干脆不显示（避免闪一个假的 0 B/s）。
    private(set) var hasBaseline = false

    @discardableResult
    func sample() -> NetworkSpeedSample {
        let now = Date()
        let counters = Self.readCounters()

        var rxDelta: UInt64 = 0
        var txDelta: UInt64 = 0
        for (name, cur) in counters {
            guard let old = previous[name] else { continue }   // 新出现的接口：本拍不计
            rxDelta += Self.delta(from: old.rx, to: cur.rx)
            txDelta += Self.delta(from: old.tx, to: cur.tx)
        }
        previous = counters

        var result = NetworkSpeedSample.zero
        if let lastTime = previousTime {
            let dt = now.timeIntervalSince(lastTime)
            // 休眠唤醒 / 时钟跳变时 dt 会异常，宁可这一拍显示 0，也不要甩出一个假峰值。
            if dt > 0.05, dt < 10 {
                result.rxBytesPerSec = Double(rxDelta) / dt
                result.txBytesPerSec = Double(txDelta) / dt
                hasBaseline = true
            }
        }
        previousTime = now
        latest = result
        return result
    }

    /// 32 位计数器回绕补偿：新值比旧值小 = 中间绕过了一次 2³²。
    private static func delta(from old: UInt32, to new: UInt32) -> UInt64 {
        new >= old ? UInt64(new - old) : UInt64(new) + (0x1_0000_0000 - UInt64(old))
    }

    /// 只认物理网卡：en*/pdp_ip*。
    private static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    private static func readCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        var offset = 0
        while offset + MemoryLayout<NetIfMsghdr2>.size <= length {
            let header = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: NetIfMsghdr2.self)
            }
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0 else { break }

            // RTM_IFINFO2 = 0x12，只有它带 64 位 if_data64 布局。
            if header.ifm_type == 0x12,
               header.ifm_flags & IFF_UP != 0,
               header.ifm_flags & IFF_LOOPBACK == 0 {
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(header.ifm_index), &nameBuffer) != nil {
                    let name = String(cString: nameBuffer)
                    if isPhysical(name) {
                        result[name] = (header.ifm_data.ifi_ibytes, header.ifm_data.ifi_obytes)
                    }
                }
            }
            offset += messageLength
        }
        return result
    }
}

// MARK: - if_msghdr2 布局
//
// Swift 不导出这两个结构体，按 `<net/if.h>` 的定义手工声明。
// 注意 if_data64 到 ifi_lastchange 就结束了（128 字节），后面那四个
// u_int32_t 属于 32 位的 if_data，不属于 if_data64 —— 多写会让
// if_msghdr2 从 160 字节变成 176 字节，导致后面 sockaddr_dl 解析错位。

struct NetIfMsghdr2 {
    var ifm_msglen: UInt16 = 0
    var ifm_version: UInt8 = 0
    var ifm_type: UInt8 = 0
    var ifm_addrs: Int32 = 0
    var ifm_flags: Int32 = 0
    var ifm_index: UInt16 = 0
    var ifm_snd_len: Int32 = 0
    var ifm_snd_maxlen: Int32 = 0
    var ifm_snd_drops: Int32 = 0
    var ifm_timer: Int32 = 0
    var ifm_data: NetIfData64 = NetIfData64()
}

struct NetIfData64 {
    var ifi_type: UInt8 = 0
    var ifi_typelen: UInt8 = 0
    var ifi_physical: UInt8 = 0
    var ifi_addrlen: UInt8 = 0
    var ifi_hdrlen: UInt8 = 0
    var ifi_recvquota: UInt8 = 0
    var ifi_xmitquota: UInt8 = 0
    var ifi_unused1: UInt8 = 0
    var ifi_mtu: UInt32 = 0
    var ifi_metric: UInt32 = 0
    var ifi_baudrate: UInt64 = 0
    var ifi_ipackets: UInt64 = 0
    var ifi_ierrors: UInt64 = 0
    var ifi_opackets: UInt64 = 0
    var ifi_oerrors: UInt64 = 0
    var ifi_collisions: UInt64 = 0
    var ifi_ibytes: UInt32 = 0
    var ifi_ibytes_high: UInt32 = 0
    var ifi_obytes: UInt32 = 0
    var ifi_obytes_high: UInt32 = 0
    var ifi_imcasts: UInt64 = 0
    var ifi_omcasts: UInt64 = 0
    var ifi_iqdrops: UInt64 = 0
    var ifi_noproto: UInt64 = 0
    var ifi_recvtiming: UInt32 = 0
    var ifi_xmittiming: UInt32 = 0
    var ifi_lastchange_sec: Int32 = 0
    var ifi_lastchange_usec: Int32 = 0
}

// MARK: - 菜单读数

enum NetReadings {
    static func network(_ s: NetworkSpeedSample) -> String {
        "↓\(RateFormat.full(s.rxBytesPerSec)) ↑\(RateFormat.full(s.txBytesPerSec))"
    }
}
