//
//  CaptureBench.swift
//  Waycast
//
//  开发者诊断：把「按 F1 → 覆盖层可见」这段延迟拆开量一遍，找出真正的大头。
//  只测量、不改状态；跑完把报告写到文件（GUI app 的 stdout 看不到）。
//
//  触发：
//    defaults write com.waycast.macos WAYCAST_CAPTURE_BENCH -bool true
//    defaults write com.waycast.macos WAYCAST_CAPTURE_BENCH_EXIT -bool true   # 跑完即退
//    defaults write com.waycast.macos WAYCAST_BENCH_OUT -string /tmp/waycast_capture_bench.txt
//

import AppKit

@MainActor
enum CaptureBench {

    static func run(iterations: Int = 5, exitWhenDone: Bool = false) {
        Task { @MainActor in
            var report: [String] = []
            report.append("Waycast capture bench — \(Date())")
            report.append("screen recording granted: \(CGPreflightScreenCaptureAccess())")
            report.append("")

            // 「干净单发」模式：不跑那些会连续抓几十次屏的路径基准，只做几次
            // 真实的 start()→presented，力求复现用户按一下 F1 的手感。
            //   defaults write com.waycast.macos WAYCAST_CAPTURE_BENCH_QUICK -bool true
            if UserDefaults.standard.bool(forKey: "WAYCAST_CAPTURE_BENCH_QUICK") {
                report.append("-- quick: 干净单发（无前置负载）--")
                let c = AppDelegate.shared.captureController
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // 让系统静下来
                for i in 0..<max(1, iterations) {
                    let t = CACurrentMediaTime()
                    let marks = await presentedOnce(ctrl: c)
                    report.append("  第 \(i + 1) 次：总计 \(String(format: "%6.1f", (CACurrentMediaTime() - t) * 1000)) ms")
                    for (name, at) in marks {
                        report.append(String(format: "        %7.1f ms   %@", at, name as NSString))
                    }
                    c.cancel()
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                write(report, exitWhenDone: exitWhenDone)
                return
            }

            // ① CGPreflightScreenCaptureAccess() 本身是 XPC 调用 —— 量一下它值多少钱。
            report.append("-- preflight（每次按 F1 都会走一遍）--")
            for i in 0..<iterations {
                let t = CACurrentMediaTime()
                _ = CGPreflightScreenCaptureAccess()
                report.append("  preflight[\(i)]  \(ms(t)) ms")
            }

            // ② 抓帧各路径 + 单显示器分解。
            report.append("")
            report.append("-- capture paths --")
            report.append(await FrozenCapture.bench(iterations: iterations))

            // ③ 空壳纯净度：空壳显形后抓一帧，跟实时帧逐像素比。均值差应该≈0，
            //    否则说明覆盖层被录进了冻结帧（会看到整屏发灰）。
            report.append("")
            report.append("-- shell purity（空壳会不会被录进抓帧）--")
            let ctrlForShell = AppDelegate.shared.captureController
            if let before = try? await FrozenCapture.captureAllScreens(), let base = before.first {
                ctrlForShell.debugPresentShellsOnly()
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let after = try? await FrozenCapture.captureAllScreens(), let probe = after.first {
                    report.append(String(format: "  空壳显形前后 平均像素差 = %.3f / 255（越接近 0 越干净）",
                                         meanPixelDiff(base.image, probe.image)))
                    report.append("  参考：若遮罩被录进去，这个值会跳到 20 以上")
                }
                ctrlForShell.cancel()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            // ④ 端到端：start() → 覆盖层可见。空壳开/关交替跑，做 A/B ——
            //    覆盖层一旦显形就可能逼合成器整屏重绘，会不会把抓帧拖慢，必须实测。
            report.append("")
            report.append("-- end-to-end A/B（空壳开 / 关 交替）--")
            let ctrl = AppDelegate.shared.captureController
            var withShell: [Double] = []
            var withoutShell: [Double] = []
            for i in 0..<(iterations * 2) {
                let useShell = (i % 2 == 0)
                ctrl.shellEnabled = useShell
                let t = CACurrentMediaTime()
                let marks = await presentedOnce(ctrl: ctrl)
                let total = (CACurrentMediaTime() - t) * 1000
                let captureAt = marks.first(where: { $0.0.contains("抓帧完成") })?.1 ?? -1
                let shellAt = marks.first(where: { $0.0.contains("空壳") })?.1
                let shellNote = shellAt.map { "   空壳 \(String(format: "%.1f", $0)) ms" } ?? ""
                report.append("  [\(useShell ? "空壳开" : "空壳关")]"
                              + "  总计 \(String(format: "%6.1f", total)) ms"
                              + "   抓帧完成于 \(String(format: "%6.1f", captureAt)) ms" + shellNote)
                if useShell { withShell.append(captureAt) } else { withoutShell.append(captureAt) }
                ctrl.cancel()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            func avg(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.reduce(0, +) / Double(a.count) }
            report.append(String(format: "  抓帧均值：空壳开 %.1f ms ｜ 空壳关 %.1f ms",
                                 avg(withShell), avg(withoutShell)))
            ctrl.shellEnabled = true

            write(report, exitWhenDone: exitWhenDone)
        }
    }

    private static func write(_ report: [String], exitWhenDone: Bool) {
        let text = report.joined(separator: "\n")
        let path = UserDefaults.standard.string(forKey: "WAYCAST_BENCH_OUT")
            ?? "/tmp/waycast_capture_bench.txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print(text)
        if exitWhenDone { NSApp.terminate(nil) }
    }

    /// 跑一次真实的截图会话，等 `onPresented` 回调（带 6 秒兜底，避免权限缺失时挂死）。
    private static func presentedOnce(ctrl: CaptureController) async -> [(String, Double)] {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = {
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
            ctrl.onPresented = { finish() }
            ctrl.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                MainActor.assumeIsolated { finish() }
            }
        }
        ctrl.onPresented = nil
        return ctrl.phaseMarks
    }

    private static func ms(_ t: CFTimeInterval) -> String {
        String(format: "%7.1f", (CACurrentMediaTime() - t) * 1000)
    }

    /// 合成一次 ⌘Z。走的是和真人按键**同一条**链路（WindowServer → 会话事件流 →
    /// 前台窗口），所以拿它验「⌘Z 能不能到截图覆盖层」是有意义的 —— 不是直接调
    /// 撤销函数那种绕过链路的假验证。
    static func synthCommandZ() {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil,
                                  virtualKey: 6,   // kVK_ANSI_Z
                                  keyDown: down) else { continue }
            e.flags = .maskCommand
            e.post(tap: .cgSessionEventTap)
            usleep(40_000)
        }
    }

    /// 把两张图缩到 256×144 后求逐字节平均绝对差（0…255）。
    private static func meanPixelDiff(_ a: CGImage, _ b: CGImage) -> Double {
        let w = 256, h = 144, bpr = w * 4
        var bufA = [UInt8](repeating: 0, count: bpr * h)
        var bufB = [UInt8](repeating: 0, count: bpr * h)
        let space = CGColorSpaceCreateDeviceRGB()
        func render(_ img: CGImage, _ buf: inout [UInt8]) {
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: bpr, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        render(a, &bufA)
        render(b, &bufB)
        var sum = 0.0
        for i in 0..<bufA.count { sum += abs(Double(bufA[i]) - Double(bufB[i])) }
        return sum / Double(bufA.count)
    }
}
