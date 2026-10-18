# 2026-10-18 截图延迟：按键后要等近 1 秒

用户报告：macOS 27 上按截图热键，覆盖层「几乎最少 1 秒」才出来；macOS 15 时没有这么慢。

## 结论（已修）

不是抓帧变慢了，是**那条流路径根本没跑成功**，每次都在静默降级：

```
F1 → SCStream 启流 → 首帧在 startCapture() 返回前就到 → 老抓帧器把这一帧丢掉
   → firstFrame() 立刻抛错 → 缓存命中时再试一次（还是丢）
   → 降级 /usr/sbin/screencapture CLI（185–210 ms，且会放系统整屏缩放动画）
   → 300–350 ms 才拿到帧，叠加缩放动画 ⇒ 手感 ≈1 秒
```

根因是一段状态机竞态：`SingleFrameGrabber.finish()` 里若还没有等待者（continuation 为 nil），
只把 `finished = true` 就返回，帧被丢弃；随后 `firstFrame()` 见 `finished` 已真，直接抛
`captureFailed`。macOS 15 上首帧通常晚于 `startCapture()` 返回，踩不到；macOS 27 上
`startCapture()` 变成 ~57 ms，首帧更早，独立复现脚本 10 次里 8 次踩中。

## 改动

`Sources/Waycast/Capture/FrozenCapture.swift`

1. `SingleFrameGrabber` 改为「先存结果、后接等待者」：早到的帧进 `result`，等待者一注册就交付。
2. `firstFrame()` 不再同步 `await stopCapture()`（实测 10–29 ms），丢后台停流。
3. 兜底顺序：26+ 先试 `SCScreenshotManager.captureScreenshot`（实测 24–33 ms、保留窗口阴影），
   CLI 降到最后一档（~200 ms + 缩放动画）。

## 验证

- 独立复现（同构抓帧器）：修复前 10 次成功 2 次，修复后 10/10，按键→拿到帧 55–66 ms。
- 应用内基准（`WAYCAST_CAPTURE_BENCH_QUICK`，5 连发）：
  - 修复前：总计 350–400 ms，`抓帧完成` 300–350 ms，`path stream` 5 次里 4 次 `ok=-1`。
  - 修复后：总计 **40–55 ms**，`抓帧完成` 40–50 ms，流路径不再降级。
- 端到端：合成 F1 → 0.25 s 后整屏平均亮度 0.796 → 0.437（45% 遮罩已铺），Esc 后回到 0.796。

## 已知边界

- 重新构建会换 ad-hoc 签名（cdhash），本机屏幕录制授权这次没掉，但不保证每次都在，掉了就重新授权一次。
- 剩下的 40–50 ms 几乎全是 SCStream 启流。要再往 0 压只能常驻一条流（按键直接取最新帧），
  代价是系统一直亮着「屏幕录制」指示、以及常驻开销；实测静止画面下流不推帧（2 秒 0 帧），
  常驻帧与实时画面一致，但动态内容会旧一帧。未采用。
