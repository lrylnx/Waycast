# Waycast

一款 macOS 菜单栏效率工具，把**环形应用切换、截图标注、贴图、Spotlight 式搜索、剪贴板历史、输入法锁定、状态栏系统监控（内存水位 / 网速 / CPU 温度与占用率）**整合进一个常驻状态栏的应用。无 Dock 图标，随叫随到。

## 功能一览

| 功能 | 呼出方式 | 说明 |
|---|---|---|
| 环形应用切换 (AppRing) | `⌘Tab` / 鼠标侧键 | 接管系统切换器，光标处弹出毛玻璃圆盘 |
| 截图 | `F1`（可自定义） | 全屏框选 + 标注工具栏 + OCR |
| 贴图 | `F3`（可自定义） | 框选区域钉在屏幕最上层 |
| 搜索面板 | 状态栏菜单 / 自定义快捷键 | Spotlight 式启动器，支持中英文应用名 |
| 剪贴板历史 | 状态栏菜单 | 文本历史，跨重启持久化 |
| 锁定输入法 | 状态栏菜单 | 固定当前输入法，防止误切 |
| 状态栏图标 | 状态栏菜单 / 设置 | 内存水位、实时网速、CPU 温度 + 占用率三选一，或回到默认闪电 |

所有功能都汇聚到右上角状态栏图标的一个菜单里：

![状态栏菜单](docs/screenshots/status-menu.png)

---

## 1. 环形应用切换 (AppRing)

用 `⌘Tab` 直接接管系统切换器，在**鼠标指针所在位置**弹出一个毛玻璃圆盘，按最近使用（MRU）顺序排列应用图标。按住修饰键、点按呼出键唤出圆环，松开即切换到选中的 App——肌肉记忆与系统切换器完全一致。

![环形切换器](docs/screenshots/appring-ring.png)

悬停在一个拥有多个窗口的应用上，会展开「窗口花瓣」，显示每个窗口的实时缩略图与标题，点选即可聚焦到具体那个窗口（窗口级切换）。

![窗口花瓣与实时缩略图](docs/screenshots/appring-petals.png)

**设置项**（见下方设置界面）：
- 启用/禁用总开关（关闭后 `⌘Tab` 恢复系统原生行为）
- 呼出快捷键自定义（可捕获 `⌘Tab` 本身）
- 鼠标侧键（按键 4 / 5）呼出开关

## 2. 截图

`F1` 进入全屏截图遮罩，拖拽框选区域。选区确定后浮现标注工具栏，支持：

- **移动 / 矩形 / 画笔 / 箭头 / 文字 / 马赛克** 六种工具
- **OCR 文字识别**（中英文，结果自动复制并可编辑）
- **保存**（默认导出到桌面）/ **复制到剪贴板** / **贴图**
- 撤销、颜色选择、线宽/字号调节（选中工具后滚动滚轮）
- 圆角矩形选区、任意工具模式下拖拽控制点缩放选区
- 右键任意处或 `Esc` 取消，双击或 `⌘C` 快速完成

![截图标注工具栏](docs/screenshots/screenshot-toolbar.png)

### 遮罩强度

进入截图态后，选区**之外**的区域会被黑色遮罩压暗，让选区「跳出来」。强度默认 **45%**，可以在 **设置 › 截图 › 选区外遮罩** 拖滑块调，也可以直接写默认值：

```bash
defaults write com.waycast.macos captureDimOpacity -float 0.6   # 0…1，0 = 完全不压暗
```

遮罩带 200 ms 缓入：第一帧与实时屏幕**逐像素一致**，之后 120 Hz 渐入，所以进场不会被闪一下。强度在会话开始时快照一次，不在重绘路径里读 UserDefaults。

### 工具栏材质（液态玻璃）

标注工具栏、贴图窗口的悬停工具条都走 **`NSGlassEffectView`**（macOS 26 起 AppKit 原生提供）—— 就是系统那套**液态玻璃**：实时折射并模糊它下面的画面、跟随浅色/深色外观自适应、圆角是连续圆角；macOS 27 起还开了 `effectIsInteractive`，按下有玻璃回弹。压在彩色内容上时折射最明显（对着 Dock 图标带截图，能看到图标被模糊后从工具栏里透出来）。真机前后对比见 `build/capture-before-after.png`。

低于 macOS 26 时由 `Sources/Waycast/Core/LiquidGlass.swift` 的 `GlassBackdrop` 统一退回「96% 不透明底色 + 1px 高光描边 + 投影」，观感接近但不折射。**新加浮动工具条请一并走 `GlassBackdrop.wrap(_:cornerRadius:)`**，别各自设 `layer.backgroundColor`，否则新老系统会各写一套样式。

**SwiftUI 侧的玻璃**走同一个文件里的 `.glassPanel(cornerRadius:)` —— 底层同样是 `NSGlassEffectView`，但用的是系统给 SwiftUI 的 `.glassEffect(_:in:)` modifier，能正常参与 SwiftUI 的布局 / 动画 / 圆角裁剪，不必套一层 `NSViewRepresentable`（那样要么尺寸对不上，要么状态被隔离）。

> 玻璃只能折射它**下面**的画面。截图覆盖层是同一个窗口里先铺冻结帧+遮罩、再叠工具栏，所以玻璃透出的是「已经被遮罩压暗的」内容，视觉上正好是一块浮在暗幕上的玻璃，层次是对的。

### 调试钩子

```bash
# 启动即进入截图态（省得按热键；F1 常被系统亮度功能占用）
defaults write com.waycast.macos WAYCAST_AUTO_CAPTURE -bool true
defaults write com.waycast.macos WAYCAST_AUTO_CAPTURE_DELAY -float 2.5   # 默认 1 秒

# 不碰任何截图 API，直接给合成纯色帧（隔离 UI 问题时用）
defaults write com.waycast.macos WAYCAST_NO_CAPTURE -bool true

# 启动即打开搜索面板（验证面板 UI / 材质用）
defaults write com.waycast.macos WAYCAST_AUTO_SEARCH -bool true
defaults write com.waycast.macos WAYCAST_AUTO_SEARCH_DELAY -float 2.0   # 默认 1.5 秒
defaults write com.waycast.macos WAYCAST_AUTO_QUERY -string "切换"       # 选填：自动填入并展开结果
```

这些都**用完就删**（`defaults delete com.waycast.macos WAYCAST_AUTO_CAPTURE`），否则每次开 App 都会自动弹。走 `defaults` 而不是环境变量是有意的：从终端直接跑可执行文件会把「屏幕录制」权限算到终端头上，截图会失败。

## 3. 贴图 (Pin)

`F3` 框选一块屏幕区域，直接把它作为浮动窗口钉在屏幕最上层，适合对照参考、临时置顶信息。

## 4. Spotlight 式搜索面板

- 锚定在屏幕顶部、固定搜索框、结果向下展开，与原生 Spotlight 交互一致
- **中英文双向匹配**：既能搜英文文件名，也能搜 App 的中文本地化显示名（如「磁盘工具」「活动监视器」「日历」）
- 图片 / 视频结果显示缩略图（QuickLook 生成 + 缓存）
- 结果列表中的文件可**直接拖拽**到访达、邮件、聊天窗口等任意位置
- 点击面板外部一律关闭；支持中文输入法合成期间的回车提交
- 搜索面板位置按显示器记忆
- 面板底是 **macOS 26 液态玻璃**（`.glassEffect`），默认 `regular`。
  - `regular`（系统默认）：模糊 + 提亮最强，可读性最好 —— **定稿值**
  - `clear`：几乎不模糊，背景**锐利穿透**，列表文字会和背后内容混在一起
  - `mix`：`clear` 玻璃 + 一层 `.ultraThinMaterial` 垫层，通透与柔化的折中
  - 后两种仅作调试保留：`defaults write com.waycast.macos WAYCAST_GLASS_VARIANT -string regular|clear|mix`
- 面板的投影是**玻璃层自绘的圆角阴影**（`PanelShadowMode.soft`，默认）。
  - 为什么不用系统窗口阴影：`hasShadow` 生成的阴影按**窗口 frame**（矩形）计算，四角必然是**直角**，
    在圆角玻璃下方会尖出两个角，不贴合 UI。自绘阴影取「与玻璃完全相同的圆角矩形」再 `blur` 向外扩散，
    轮廓跟着玻璃圆角走。左右下角实拍对比：`build/search-panel-shadow-round-bl.png`
  - 代价：自绘阴影要向外扩散，窗口必须留一圈透明留白（`SearchPanelLayout.padding = PanelShadowMode.outerPadding`，**44pt**），
    否则阴影会被窗口边界**硬裁** —— 阴影还没衰减完就断掉，视觉上就是面板下方一条明显的横线。
    `blur(radius: r)` 的可见扩散约 **2.5–3 × r**，留白必须 ≥ 这个值（定稿：留白 44 / `r = 12`）。
    **这个留白只在关掉系统阴影时才安全** —— `hasShadow = false` 与「有留白」必须同时成立。
    - 实测（纯白背景 + 逐行亮度剖面）：留白 22 + `r 9` → 阴影跨度 22pt，窗口边界前 3px 亮度跳变 **+0.038**（可见硬边）；
      留白 44 + `r 12` → 跨度 36pt，同样指标 **+0.004**（平缓）。对比图：`build/search-panel-shadow-natural.png`
  - ⚠️ 反过来，只要**开着**系统窗口阴影，留白就必须是 **0**：系统阴影最暗处永远落在**窗口边缘**，
    留白会把它「晾」在玻璃外侧，成为面板下方一条多余的黑线（底缘剖面变成 0.703 → **0.478** → 0.612
    的「先暗后亮」非单调形态）。`.titled` 窗口的 28pt titlebar 被 SwiftUI 当 safe area，会造成同样的错位。
  - 切换：`defaults write com.waycast.macos WAYCAST_SHADOW_MODE -string soft|system|none`（`system` = 旧的直角观感）
  - 面板位置记忆存的是**玻璃**左上角而不是窗口的 —— 窗口四周有一圈留白，存窗口角会让留白取值一变位置就漂。
  - 历史问题的像素剖面实录（黑线 = 非单调塌陷）：`build/search-panel-edge-fix.png`、`build/search-panel-corner-fix.png`

## 5. 剪贴板历史

- 自动记录复制过的文本内容，条数可配置（默认 50）
- 点击任意历史条目即可重新复制到剪贴板
- **跨应用重启持久化**（原子写入本地文件，不会丢失）

## 6. 锁定输入法

一键锁定当前输入法，避免在全屏应用或游戏中误触切换。

## 7. 状态栏图标（内存水位 / 网速 / CPU 温度）

状态栏只有一个位置，所以这三种读数**四选一**（加上默认闪电图标）。在状态栏菜单里勾选切换，再点一次当前选中的那个就切回默认闪电图标；设置界面里也有同样的单选。

打开菜单时，这三项会直接带上**实时读数**，不用先切过去看：

```
✓ 网速图标  ↓1.2 MB/s ↑340 KB/s
  内存水位图标  58%
  CPU 温度  48°C · 24%
```

- **内存水位杯**：动态水位杯，按占用显示蓝 / 黄 / 红三色，波浪以 1fps 流动。
- **网速**：状态栏实时显示所有物理网卡（Wi-Fi / 有线 / 个人热点）的合计上下行速率，每秒刷新。图标里**上下两行**，上排上行 `↑`、下排下行 `↓`（箭头朝向和所在行的位置对应）。
- **CPU 温度 + 占用率**：图标**上下两行**——上排是 CPU 总占用率（`24%`），下排是温度（`48°C`），都是 3~4 字符、逐格对齐。温度取所有 CPU 核心里最高的那一路（SMC `TC10`–`TC53`），每秒刷新；占用率走 `host_statistics` 的 CPU tick 增量。低于 75°C 跟随菜单栏明暗自动取色；75–90°C 转橙、≥90°C 转红。

  > 早期版本这个图标只有一行温度。一行字却要占 **36pt** 宽（菜单栏里默认的闪电图标墨迹只有 13px、内存水位杯 18px），上下还空着，又宽又单调。改成两行后占位反而降到 **30pt**，还多带了一个读数。

三种读数都只在**当前被选中时**才启动自己的 1Hz 定时器，没启用的完全不采样、不重绘。实测（macOS 26 / Apple Silicon）开启任一读数时进程 CPU 约 **0.03%**，关闭即归零。

### 实现备注

- **CPU 温度**：走 **AppleSMC**，取 `TC10`–`TC53`（20 个 CPU 核心温度键）里最高的那一路。SMC 打不开时自动退回 IOHID 的 `PMU tdie*` 兜底。**不需要 root，也不需要任何新权限。**

  > 这里踩过一个坑。早先版本用的是 IOHID 的 `PMU tdie*`，理由是「Apple Silicon 上 AppleSMC 已经没有 CPU 温度键了」——**这个判断是错的**：AppleSMC 完全可用，只是键名从 Intel 的 `TC0P` 换成了 `TC10`–`TC53`。而 `PMU tdie*` 虽然读得到、刷新率也有 3.5Hz，读数却对负载几乎无响应：
  >
  > | 通道 | 空闲 | 10 核满载 60 秒 | 涨幅 |
  > |---|---|---|---|
  > | IOHID `PMU tdie*` | 46.5°C | 47.9°C | +1.4°C |
  > | SMC `TC10`–`TC53` | 50.2°C | 61.9°C | **+11.6°C** |
  >
  > 原因是 `PMU tdie*` 那 11 个「核心」读数彼此差不到 0.6°C —— 真实多核 CPU 不可能这么整齐，说明它是 **SoC 级平均温度**，多核一摊薄就对负载失去响应，表现为「跑满大负荷才慢吞吞升 1 度」。
- **CPU 占用率**：`host_statistics(HOST_CPU_LOAD_INFO)` 取 CPU tick 计数，两次采样求增量 —— 和 `top` 同源，只读一份全局计数，**不需要遍历进程**（遍历要 root，且贵几个数量级）。几个细节：
  - 首拍只建立基线、算不出占用率，这时图标显示 `--%` 占位符，1 秒后变成真值。
  - tick 是 `UInt32`、会回绕，按接口单独做了 2³² 补偿。
  - 两拍挨得太近时 tick 可能一个都没走（Timer 会合帧、也会被负载推迟）。这时**沿用上一次的值**而不是返回 nil —— 否则图标会毫无理由地闪回 `--%` 占位符。
  - 加了指数滑动平均（α=0.5）：1 秒窗口的原始占用率跳得很厉害（空闲时也会在 0 → 12 → 4 之间乱蹦），直接显示看着像故障。
  - **菜单里的占用率只在图标正在跑时才显示**（`isFresh`）。占用率是增量量，图标没跑时现采一次算出来的是「上次采样到现在」的平均，跨度可能几小时，显示它比不显示更糟。
- **网速**：走 `sysctl(NET_RT_IFLIST2)`。注意两个坑——(1) 只统计物理网卡，否则开 VPN 时同一份流量会在 `en0` 和 `utunN` 上被重复计一遍；(2) 实测内核往 `ifm_data.ifi_ibytes` 的 64 位字段里**只写低 32 位**（`netstat` 报 19.2 GB 时这里读到 2.02 GB，正好差 4×2³²），所以计数器每 4 GiB 回绕一次，代码里按接口单独做了回绕补偿。
- **图标宽度**：状态栏图标每秒重绘，宽度一变整排菜单栏图标都会左右抖。因此这几个图标都用 SF Mono 并按固定字符数排版——网速**上下两行**、每行恒为 5 字符（`↑340K` / `↓1.2M`）；CPU 是**上下两行**，上排占用率 3~4 字符（`08%` / `100%`）、下排温度 4~5 字符（`08°C` / `100°C`）。实测 SF Mono 每个字符宽度完全一致（11pt 下恒为 6.80pt），且**字重不影响字符宽度**，所以加粗不占额外位置。最终占位（实测墨迹）：内存水位杯 **18pt**、网速 **36pt × 20pt**、CPU **30pt × 20pt**，宽度都恒定不抖。

  > CPU 图标里 **占用率和温度都要补前导零**（`8%` → `08%`、`8°C` → `08°C`）：不补的话数字的位次会随读数左右跳（`8%` 是 2 字符、`19%` 是 3 字符），两行看着不齐。
  >
  > 位数会变的读数（`24%` ↔ `100%`）靠 `StatusTextIcon.render` 的 `widthTemplate` 参数**预留宽度**：传一段样板文字（`"100%"`），图标就按它的宽度定宽，即使当前只有 3 字符也不会变窄。**不要靠补前导空格来凑定宽** —— 空格没有墨，等于把整块墨迹往右推（实测 `" 42°C"` 按该宽度对齐后左边空 7.8pt、右边只剩 1pt，明显偏右）。
  >
  > 唯一的例外是温度上到 **100°C 以上**（`100°C` 是 5 字符），图标会临时宽到 36pt。刻意不按 5 字符预留：那会让图标**永远**是 36pt，而 100°C+ 是极罕见的过热状态，不值得为它常态化多占 6pt。
- **字重与对齐**：文字图标统一用 SF Mono **`.heavy`**。实测把所有"加粗"做法都渲染出来扫像素、算墨迹覆盖率（墨迹像素数 ÷ 墨迹包围盒面积）：11pt bold 是 0.358、**11pt heavy 是 0.438**、11pt bold + `strokeWidth` -1.2 是 0.398，而 **12pt bold 仍是 0.358** —— 加大字号只放大整体、几乎不加粗笔画，还会让两行图标从 20pt 涨到 22pt 顶满菜单栏。所以选 `.heavy`：加粗 22%，尺寸分毫不变。水平方向，**多行图标每行各自在自己的宽度里居中**，两行的视觉中心因而重合（网速靠它让上下两个箭头对齐，CPU 靠它在 3 字符 / 4 字符之间切换时保持居中）。
- **垂直位置**：不需要手动调。实测 `NSStatusBarButton` 的 `cell.imageRect(forBounds:)`，9pt / 14pt / 20pt 三种高度的图片分别落在 y=6.5 / 4.0 / 1.0，全部精确居中于 22pt 的按钮 —— 系统自己会居中。所以图标高度就是墨迹高度，多出来的空白一律不加。
- **网速和 CPU 为什么都竖着排**：并排写（`↓1.2M↑340K`）要横占 10 个字符 ≈ 70pt，把右边一排菜单栏图标挤走一大截；拆成上下两行后宽度直接减半到 36pt。代价是高度——11pt 字体按**自然行距**排两行需要 30pt，超过菜单栏的 22pt（`NSStatusBar.system.thickness`）。所以图标不是交给 `NSAttributedString` 去排版，而是用 CoreText 的 `.useGlyphPathBounds` 量出每行**字形墨迹**的实际高度（数字+箭头约 8pt），只按墨高堆叠、行间留 2pt，两层合计 20pt，稳稳落在菜单栏里。

## 8. 开机自启

设置界面提供「开机自启动」开关（基于 macOS 原生 `SMAppService`）。

---

## 设置界面

所有可配置项集中在一个设置窗口：

![设置界面](docs/screenshots/settings.png)

包含：开机自启、全局快捷键（搜索 / 截图 / 贴图）、环形应用切换 (AppRing)、状态栏图标、剪贴板历史条数、使用提示。

## 权限说明

Waycast 需要以下系统权限，首次启动会自动引导授权：

- **屏幕录制**：截图、贴图、搜索缩略图、AppRing 窗口花瓣实时缩略图
- **辅助功能 (Accessibility)**：AppRing 环形切换器的事件拦截（`⌘Tab` 接管）

> 注意：从独立 AppRing 整合而来后，辅助功能权限的主体变为 **Waycast**，请在「系统设置 › 隐私与安全性 › 辅助功能」中勾选 Waycast。

状态栏的内存水位、网速、CPU 温度三项**不需要任何额外权限**，也不需要 root。

## 下载与安装

前往 [Releases](https://github.com/lrylnx/Waycast/releases) 页面下载 `Waycast.zip`，解压后将 `Waycast.app` 拖入「应用程序」文件夹，首次运行按提示授予权限即可。

> **首次打开被系统拦截？** Waycast 使用 ad-hoc 签名、未经 Apple 公证，从浏览器下载后 macOS 会加上隔离属性，双击可能提示「无法打开，因为 Apple 无法验证」。任选其一解决：
>
> - 在「应用程序」里**右键点按** Waycast → **打开**，在弹窗中再点一次「打开」；
> - 或执行一次：`xattr -dr com.apple.quarantine /Applications/Waycast.app`
>
> 之后正常双击即可。

## 应用图标（macOS 26 / 27 的浮动托盘问题）

### 症状

在 macOS 26 Tahoe 及以后的系统上，Waycast 的图标比旁边的 App 明显小一圈，外面还套着一个灰色圆角方块。

### 原因

macOS 26 起苹果把 App 图标统一成「Liquid Glass」的圆角方形，并且会**检查 App 自带图标的形状**。判定为旧式图标的（传统的 `.icns`——图稿自带留白、圆角、投影），系统会把它**缩小约 20% 再垫一块灰色托盘**放在后面（社区俗称 icon jail / gray box of shame）。

判断依据不是 App 的 Info.plist 写了什么，而是图标本身：Safari、Xcode、ToDesk 这些满格显示的 App，Resources 里都有 `Assets.car` + `CFBundleIconName`。

### 修法

用 macOS 26 的新图标格式 `.icon` 重新出一份，编译成 `Assets.car`：

| 文件 | 作用 |
| --- | --- |
| `Resources/AppIcon.icon/` | Icon Composer 源文件（`icon.json` + `Assets/*.png` 图层） |
| `Resources/Assets.car` | 由上面的源文件经 `actool` 编译出的资源目录（已入库） |
| `Resources/AppIcon.icns` | 老系统（macOS 14/15）的回退图标，保持不变 |
| `Resources/Info.plist` | 新增 `CFBundleIconName = AppIcon` |

改图标：

```bash
# 用 Xcode 自带的 Icon Composer 打开 Resources/AppIcon.icon 编辑图层
./icon.sh --preview   # 重新编译 Assets.car，并导出四种外观的预览图到 build/
./build.sh            # build.sh 检测到素材有更新会自动重编
```

> **坑一**：`actool` 会往 `--compile` 目录里同时写一份它自己生成的 `AppIcon.icns`——只有 256px 上限。所以 `icon.sh` 先编到临时目录，只把 `Assets.car` 拿回来，绝不覆盖完整的旧版 `AppIcon.icns`。
>
> **坑二**：装好后 Finder / Dock / 启动台可能仍显示旧图标（图标缓存）。`touch` 一下 App 再 `killall Dock` 即可。
>
> **坑三**：`.icon` 是**目录**不是单文件，Finder 默认隐藏扩展名，容易和普通文件夹混淆。它是 `icon.json` + `Assets/` 两个东西。

## 系统要求

macOS 14.0 或更高版本。
