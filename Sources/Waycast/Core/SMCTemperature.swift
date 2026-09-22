import Foundation
import IOKit

/// AppleSMC 的 CPU 核心温度读取。
///
/// ## 为什么不用 IOHID 的 `PMU tdie*`（本机实测，M1 Max / macOS 26）
///
/// 同样的 10 核满载 60 秒，两条通道的表现差 8 倍：
///
/// | 通道 | 空闲 | 满载 | 涨幅 |
/// |---|---|---|---|
/// | IOHID `PMU tdie*` | 46.5°C | 47.9°C | **+1.4°C** |
/// | SMC `TC[0-9]*` | 50.2°C | 61.9°C | **+11.6°C** |
///
/// 而且 IOHID 那 11 个「核心」读数彼此差不到 0.6°C —— 真实多核 CPU 不可能
/// 这么齐，说明它读的是 **SoC 级平均温度**，多核一摊薄就对负载几乎无响应。
/// 症状就是「跑满大负荷才慢吞吞升 1 度」。
///
/// SMC 里其他候选也一并实测过（涨幅）：`Tp0*`（CPU proximity）+11.0、
/// `TCMz` +7.5（但它是瞬态热点，空闲就能到 74°C，波动 68~82，且会误染报警色）、
/// `TPD*` +1.1（和 tdie 一样迟钝）、`TRD*` +1.5。**`TC[0-9]*` 最合适**：
/// 语义明确是 CPU 核心、量程合理（空闲 50 / 满载 62）、涨幅最大且稳定。
///
/// ## 键名
/// `TC10`–`TC53`（5 组 × 4 个，共 20 个键）。注意**必须排除** `TCMz` / `TCMb` /
/// `TCDX` / `TCHP` —— 它们同样以 "TC" 开头，但 `TCMz` 空闲就 74°C，混进来会让
/// 图标一直处于报警色。
///
/// ## 开销
/// 枚举一次 2251 个键（只在首次打开时做，约 50~100ms），之后每秒只读 20 个键，
/// 每个键一次 IPC。
final class SMCTemperatureReader {

    /// 私有 IOConnect 选择子，与 smcFanControl / iStat 等工具一致。
    private static let kernelIndex: UInt32 = 2

    private enum Command: UInt8 {
        case readBytes   = 5
        case readIndex   = 8
        case readKeyInfo = 9
    }

    /// `SMCKeyData_t` 在 arm64 上的字节布局（手工构造，避免 Swift 结构体对齐差异）。
    private enum Offset {
        static let key      = 0     // UInt32
        static let keySize  = 28    // keyInfo.dataSize  UInt32
        static let keyType  = 32    // keyInfo.dataType  UInt32
        static let command  = 42    // char data8
        static let data32   = 44    // UInt32 data32
        static let data     = 48    // SMCBytes_t data[32]
        static let structSize = 80
    }

    private var connection: io_connect_t = 0
    private var isOpen = false
    private var coreKeys: [UInt32] = []
    private var didEnumerate = false
    private var lastFailedAttempt = Date.distantPast
    /// 失败后的重试间隔：休眠唤醒等场景下 SMC 可能才变得可用，
    /// 但也不能每秒都去重新开一遍（开一次要枚举 2000+ 个键）。
    private let retryInterval: TimeInterval = 300

    /// SMC 是否可用（打不开或找不到核心键时为 false，调用方回退 IOHID）。
    var isAvailable: Bool { isOpen && !coreKeys.isEmpty }

    /// 打开 AppleSMC 并枚举 CPU 核心温度键。成功后不再重复打开。
    @discardableResult
    func open() -> Bool {
        if isOpen { return true }
        guard Date().timeIntervalSince(lastFailedAttempt) >= retryInterval else { return false }
        guard let matching = IOServiceMatching("AppleSMC") else {
            lastFailedAttempt = Date()
            return false
        }
        // Swift 里 IOServiceGetMatchingService 返回非 Optional 的 io_service_t，
        // 拿不到时是 0（MACH_PORT_NULL），不能写成 guard let。
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            lastFailedAttempt = Date()
            return false
        }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            lastFailedAttempt = Date()
            return false
        }
        connection = conn
        isOpen = true
        enumerateCoreKeys()
        if !isOpen || coreKeys.isEmpty { lastFailedAttempt = Date() }
        return isOpen
    }

    /// 所有 `TC` + 数字键里的最高温，即最热的 CPU 核心。读不到返回 nil。
    func readCoreMaximum() -> Double? {
        guard isAvailable else { return nil }
        var hottest = 0.0
        for key in coreKeys {
            guard let value = readFloat(key), value > hottest else { continue }
            hottest = value
        }
        return hottest > 0 ? hottest : nil
    }

    // MARK: - 私有

    /// 遍历全部键名，挑出 `TC` + 数字（排除 TCMz / TCMb / TCDX / TCHP）。
    private func enumerateCoreKeys() {
        guard !didEnumerate else { return }
        didEnumerate = true
        guard let total = keyCount() else { return }
        var found: [UInt32] = []
        for index in 0..<total {
            guard let key = keyName(at: index) else { continue }
            let chars = Array(key)
            guard chars.count == 4,
                  chars[0] == "T", chars[1] == "C",
                  chars[2].isNumber                     // 排除 TCMz / TCDX / TCHP
            else { continue }
            found.append(Self.fourCharCode(key))
        }
        coreKeys = found
    }

    /// `#KEY` 给出 SMC 的键总数。
    private func keyCount() -> UInt32? {
        guard let value = readRaw(Self.fourCharCode("#KEY")),
              let size = value.size, size == 4 else { return nil }
        return value.bytes.withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }
    }

    /// 按索引取键名（4 字符）。
    private func keyName(at index: UInt32) -> String? {
        var input = Self.makePacket()
        input[Int(Offset.command)] = Command.readIndex.rawValue
        Self.writeUInt32(index, into: &input, at: Offset.data32)
        guard let output = call(input) else { return nil }
        let raw = Self.readUInt32(output, at: Offset.key)
        let bytes = [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
                     UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        return String(bytes: bytes, encoding: .ascii)
    }

    /// 读一个 float 类型的温度值（`TC**` 全是 `flt `/4 字节）。
    private func readFloat(_ key: UInt32) -> Double? {
        guard let value = readRaw(key), value.type == Self.floatTypeCode,
              value.size == 4 else { return nil }
        let raw = value.bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        return Double(Float(bitPattern: raw))
    }

    /// 一次完整的「读键信息 + 读数据」。
    private func readRaw(_ key: UInt32) -> (size: Int?, type: UInt32?, bytes: [UInt8])? {
        var infoPacket = Self.makePacket()
        Self.writeUInt32(key, into: &infoPacket, at: Offset.key)
        infoPacket[Int(Offset.command)] = Command.readKeyInfo.rawValue
        guard let infoOut = call(infoPacket) else { return nil }
        let size = Int(Self.readUInt32(infoOut, at: Offset.keySize))
        let type = Self.readUInt32(infoOut, at: Offset.keyType)
        guard size > 0, size <= 32 else { return nil }

        var readPacket = Self.makePacket()
        Self.writeUInt32(key, into: &readPacket, at: Offset.key)
        Self.writeUInt32(UInt32(size), into: &readPacket, at: Offset.keySize)
        readPacket[Int(Offset.command)] = Command.readBytes.rawValue
        guard let dataOut = call(readPacket) else { return nil }
        let bytes = Array(dataOut[Offset.data..<(Offset.data + 32)])
        return (size, type, bytes)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Offset.structSize)
        var outputSize = Offset.structSize
        let result = input.withUnsafeBytes { inputPtr -> kern_return_t in
            output.withUnsafeMutableBytes { outputPtr in
                IOConnectCallStructMethod(connection,
                                          Self.kernelIndex,
                                          inputPtr.baseAddress,
                                          Offset.structSize,
                                          outputPtr.baseAddress,
                                          &outputSize)
            }
        }
        return result == kIOReturnSuccess ? output : nil
    }

    // MARK: - 字节工具

    private static let floatTypeCode = fourCharCode("flt ")

    private static func fourCharCode(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func makePacket() -> [UInt8] {
        [UInt8](repeating: 0, count: Offset.structSize)
    }

    private static func writeUInt32(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
        buffer[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func readUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }
}
