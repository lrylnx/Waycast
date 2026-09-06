import Cocoa
import Darwin

/// 状态栏「内存水位」图标 —— 移植自 MemPress 的水杯模式（去掉百分比文字、
/// 圆点模式和面板，只保留水位杯）。
///
/// 设计目标与 MemPress 一致：CPU 占用极低。
///  - 1Hz 定时器只推进波浪相位并重绘一张 18×20pt 的小位图
///  - 未启用时定时器完全销毁，零开销
///  - 采样用 host_statistics64（纯 mach 调用，无进程遍历）
final class MemoryWaterline {
    static let shared = MemoryWaterline()

    /// 图标更新回调（主线程）；nil 表示恢复默认图标。
    var onIconUpdate: ((NSImage?) -> Void)?
    /// 开关状态变化回调（主线程），供菜单勾选同步。
    var onChange: (() -> Void)?

    var isEnabled: Bool {
        get { AppSettings.shared.statusIconWaterline }
        set {
            guard newValue != isEnabled else { return }
            AppSettings.shared.statusIconWaterline = newValue
            newValue ? start() : stop()
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    func toggle() { isEnabled.toggle() }

    private init() {
        if AppSettings.shared.statusIconWaterline {
            // 启动时延迟一拍，等 AppDelegate 挂好 onIconUpdate
            DispatchQueue.main.async { [weak self] in self?.start() }
        }
    }

    // MARK: - 采样 + 动画

    private let monitor = WaterlineMemoryMonitor()
    private var timer: Timer?
    private var phase: Double = 0
    private var lastSample = WaterlineSample(total: 0, used: 0, usagePercent: 0, pressure: .low)

    private func start() {
        lastSample = monitor.sample()
        render()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2   // 允许系统合帧，省电
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        onIconUpdate?(nil)
    }

    private func tick() {
        phase += 0.35
        lastSample = monitor.sample()
        render()
    }

    private func render() {
        onIconUpdate?(Self.drawCup(sample: lastSample, phase: phase))
    }

    // MARK: - 水位杯绘制（18×20pt 位图，彩色非 template）

    private static let cupW: CGFloat = 16
    private static let cupH: CGFloat = 16
    private static let barH: CGFloat = 20

    static func drawCup(sample: WaterlineSample, phase: Double, scale: CGFloat = 2) -> NSImage {
        let widthPt = cupW + 2, heightPt = barH
        let pixelW = Int(ceil(widthPt * scale)), pixelH = Int(ceil(heightPt * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: widthPt, height: heightPt)) }

        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.scaleBy(x: scale, y: scale)

            let cupRect = NSRect(x: (widthPt - cupW) / 2, y: (barH - cupH) / 2,
                                 width: cupW, height: cupH)
            let radius: CGFloat = 2.5

            // 杯身外框
            let cupPath = NSBezierPath(roundedRect: cupRect, xRadius: radius, yRadius: radius)
            cupPath.lineWidth = 1.0
            NSColor(calibratedWhite: 1.0, alpha: 0.85).setStroke()
            cupPath.stroke()

            let level = min(max(sample.usagePercent / 100.0, 0), 1)
            let inset: CGFloat = 1.0
            let lr = cupRect.insetBy(dx: inset, dy: inset)
            let bottomY = lr.minY, topY = lr.maxY

            if level > 0.01 {
                let color = sample.pressure.color
                let fillSurfaceY = bottomY + lr.height * CGFloat(level)
                let waveAmp: CGFloat = 2.4
                let wavelength: CGFloat = cupW / 2.0

                func yAt(_ x: CGFloat, phi: CGFloat = 0) -> CGFloat {
                    let pr = CGFloat(phase) * 2 * .pi + phi
                    let a = fillSurfaceY + waveAmp * sin((x * 2 * .pi) / wavelength + pr)
                    return min(max(a, bottomY), topY)
                }

                // 液面：二次贝塞尔平滑波
                let steps = 10
                let wavePath = CGMutablePath()
                wavePath.move(to: CGPoint(x: lr.minX, y: bottomY))
                wavePath.addLine(to: CGPoint(x: lr.minX, y: yAt(lr.minX)))
                for i in 1...steps {
                    let xPrev = lr.minX + lr.width * CGFloat(i - 1) / CGFloat(steps)
                    let xCurr = lr.minX + lr.width * CGFloat(i) / CGFloat(steps)
                    let xMid = (xPrev + xCurr) * 0.5
                    wavePath.addQuadCurve(to: CGPoint(x: xCurr, y: yAt(xCurr)),
                                          control: CGPoint(x: xMid, y: yAt(xMid)))
                }
                wavePath.addLine(to: CGPoint(x: lr.maxX, y: bottomY))
                wavePath.closeSubpath()

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: cupRect, xRadius: radius, yRadius: radius).addClip()

                let cg = ctx.cgContext
                cg.saveGState()
                cg.addPath(wavePath)
                cg.clip()
                // 玻璃质感渐变（浅上深下）
                let grad = NSGradient(colors: [
                    color.blended(withFraction: 0.18, of: .white) ?? color,
                    color
                ])!
                grad.draw(in: lr, angle: -90)
                cg.restoreGState()

                // 后景暗波（相位 +π/2）：流动层次
                let backPath = CGMutablePath()
                for i in 0...steps {
                    let x = lr.minX + lr.width * CGFloat(i) / CGFloat(steps)
                    let y = yAt(x, phi: .pi / 2) * 0.45 + fillSurfaceY * 0.55
                    if i == 0 { backPath.move(to: CGPoint(x: x, y: y)) }
                    else {
                        let xPrev = lr.minX + lr.width * CGFloat(i - 1) / CGFloat(steps)
                        let xMid = (xPrev + x) * 0.5
                        backPath.addQuadCurve(to: CGPoint(x: x, y: y),
                                              control: CGPoint(x: xMid, y: y))
                    }
                }
                cg.saveGState()
                cg.setLineWidth(0.9)
                (color.blended(withFraction: 0.32, of: .black) ?? color)
                    .withAlphaComponent(0.55).setStroke()
                cg.addPath(backPath)
                cg.strokePath()
                cg.restoreGState()

                // 主波高光线
                let glowPath = CGMutablePath()
                for i in 0...steps {
                    let x = lr.minX + lr.width * CGFloat(i) / CGFloat(steps)
                    let y = yAt(x)
                    if i == 0 { glowPath.move(to: CGPoint(x: x, y: y)) }
                    else {
                        let xPrev = lr.minX + lr.width * CGFloat(i - 1) / CGFloat(steps)
                        let xMid = (xPrev + x) * 0.5
                        glowPath.addQuadCurve(to: CGPoint(x: x, y: y),
                                              control: CGPoint(x: xMid, y: y))
                    }
                }
                cg.saveGState()
                cg.setLineWidth(1.0)
                (color.blended(withFraction: 0.50, of: .white) ?? color).setStroke()
                cg.addPath(glowPath)
                cg.strokePath()
                cg.restoreGState()

                NSGraphicsContext.restoreGraphicsState()
            }

            NSGraphicsContext.restoreGraphicsState()
        }

        rep.size = NSSize(width: widthPt, height: heightPt)
        let image = NSImage(size: NSSize(width: widthPt, height: heightPt))
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - 内存采样（host_statistics64，与 MemPress 相同算法）

enum WaterlinePressure: Int {
    case low       // < 70%  蓝
    case elevated  // 70–90% 黄
    case critical  // ≥ 90%  红

    var color: NSColor {
        switch self {
        case .low:      return NSColor(calibratedRed: 0.39, green: 0.82, blue: 1.00, alpha: 1.0)
        case .elevated: return NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.04, alpha: 1.0)
        case .critical: return NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1.0)
        }
    }
}

struct WaterlineSample {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var usagePercent: Double = 0
    var pressure: WaterlinePressure = .low
}

final class WaterlineMemoryMonitor {
    private let mediumThreshold: Double = 70
    private let highThreshold: Double = 90
    private var pageSize: vm_size_t = 0
    private var totalMem: UInt64 = 0

    init() {
        var size = MemoryLayout<vm_size_t>.size
        sysctlbyname("hw.pagesize", &pageSize, &size, nil, 0)
        var m: UInt64 = 0
        var ms = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &m, &ms, nil, 0)
        totalMem = m
    }

    func sample() -> WaterlineSample {
        var s = WaterlineSample(total: totalMem)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return s }
        let free = UInt64(stats.free_count) * UInt64(pageSize)
        let active = UInt64(stats.active_count) * UInt64(pageSize)
        let inactive = UInt64(stats.inactive_count) * UInt64(pageSize)
        let wired = UInt64(stats.wire_count) * UInt64(pageSize)
        let compressed = UInt64(stats.compressor_page_count) * UInt64(pageSize)
        let speculative = UInt64(stats.speculative_count) * UInt64(pageSize)
        _ = free; _ = inactive
        // 物理已占用 = wired + active(去除 speculative) + compressed，贴近活动监视器
        let activeClean = active > speculative ? active - speculative : active
        s.used = min(wired + activeClean + compressed, totalMem)
        s.usagePercent = totalMem > 0 ? (Double(s.used) / Double(totalMem)) * 100.0 : 0
        if s.usagePercent >= highThreshold { s.pressure = .critical }
        else if s.usagePercent >= mediumThreshold { s.pressure = .elevated }
        else { s.pressure = .low }
        return s
    }
}
