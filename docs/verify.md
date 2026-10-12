# 验收与测量

## 视觉验收

`xc.sh shot` 截图（首次需给终端授予屏幕录制权限）；`--` 之后是 App 启动参数：

```bash
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark
```

- Debug 构建认一组启动参数，完整列表与含义只写在 `App/Sources/UI/Debug/DebugScene.swift`、`DebugScene+iOS.swift` 的文档注释里。产品代码只经 `DebugHooks` 碰调试画面，不认识 `DebugScene`、不写 `#if DEBUG`。调试键不写进偏好域（`UserDefaults.standard` 是真实的 `com.sugeh.cuepad`）：预填的搜索词只认启动参数。
- 窗口尺寸用 `-CuePadWindowSize` 定；不给时沿用这个隔离库上次记下的位置与尺寸（偏好在隔离库里）。
- 布局反馈环压力：`apple/scripts/layout-stress.sh`，场景与判定见脚本头注释。界面侧的约束见 [ui.md](ui.md)。

## 性能测量

测量只有一个入口：单次交互（`-CuePadBench interact`）。Mac 是 `apple/scripts/perf-mac.sh`，iOS 是 `apple/scripts/perf-ios.sh`（口径与限制见各自头注释），场景与指标在 `App/Sources/UI/Debug/InteractionBench.swift`。方法与坑：

- 前后对比以进程执行的指令数（`instructionsM`）为准：机器忙时帧间隔和 CPU 时间都会被别的进程拖歪。旧新两个构建交替各跑三遍取中位数。
- 掉帧与动画类指标必须在前台量：AppKit 的动画只在前台跑，前台每次几何变化还要重算鼠标跟踪区，后台量的数字偏乐观（`interact` 自己把实例调到前台，会抢一下焦点，集中批量跑）。窗口还得在屏幕上：放到屏幕外（`-CuePadOffscreen`）时 display link 不走，屏幕外只用于布局与日志类场景。
- 掉帧数看的是主线程上 display link 的回调间隔，反映主线程跟不跟得上，不是画面实际交出的帧率；是否真的掉帧以 Instruments 的 Animation Hitches 为准。Animation Hitches 在 iOS 模拟器上不支持，iOS 端用模拟器录屏逐帧或应用内每帧探针。
- Instruments：用 Release 优化构建并保留测量代码（`xcodebuild -configuration Release … 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'`）。
- `xctrace record --template 'Time Profiler' --attach <pid>`；`--launch` 按 bundle id 找进程，机器上有别的 CuePad 时报 ambiguous。
- SwiftUI 模板用 `--attach` 没有数据，要 `--launch` 一份换了 bundle id 的 App 副本（复制后改 `CFBundleIdentifier` 并重签名）；视图更新表与 hitch 表（`hitches`、`hitches-updates`、`hitches-renders`、`hitches-gpu`）都在里面。
- `Animation Hitches` 模板单独录会写出几十 GB，别用；`--launch` 的进程结束后可能停在暂停状态，按它的 PID 结束。

### 会话页滚动（Mac，不碰指针、不抢焦点）

`-CuePadBench chatscroll`（配 `-CuePadDemo YES -CuePadLongChat YES -CuePadScene session -CuePadSession marathon -CuePadWindowSize 1440x900 -CuePadOffscreen YES`，场景在 `DebugScene+LongChat.swift`）：对 300 轮的长对话先往上翻几趟热身，再量慢速触控板（600px/s）、快速触控板（2400px/s）、鼠标滚轮三组，每组下上下上四趟，一组一行 `CHATSCROLL {json}`，量完退出。
- 按触控板与滚轮的节奏在进程内直接挪滚动视图的裁剪区原点，补发 `willStartLiveScroll` 与 `didEndLiveScroll` 两个通知（滚动区据此知道"用户在滚"）：不碰真实指针、不向系统发事件。启动要用 `open -g -n -a <app> --stdout <文件> --env … --args …`（后台启动，不激活）：直接执行二进制会把应用调到前台抢焦点。
- 指标：主线程每圈 CPU（≥0.2ms 的圈）的 p50/p90/p99、超 6.9ms（144Hz 一帧）与 16ms 的圈数、总 CPU、进程指令数（前后对比以它为准）、`movedPx`（为 0 数字作废）。别人在编译时 CPU 时间会被拖歪，指令数基本不动；对话在热身时的排开是跟时机有关的，不同次的内容大小会差一点，要排除它就把初始排开的条数固定成同一个值再比（同一个值下三遍指令数相差不到 1%）。
- 屏幕外量不到：AppKit 的滚轮事件与动画那一段（靠 display link）、真实指针在窗口里时每帧重设光标的成本（自定义指针的机器上很贵）、合成与掉帧，这些要在前台量，没人用电脑时跑（会把应用调到前台、移动真实指针，量完放回）：
  - `-CuePadScrollDriver process`：滚轮事件在进程内交给滚动视图（`scrollWheel(with:)`），走 AppKit 的滚轮与动画，不碰指针；`hid`：经窗口服务器发真实滚轮事件，要配 `-CuePadScrollPointer in`，本窗口不在指针下的最上层就一个事件也不发、报错退出。
  - `-CuePadScrollPointer in|out`：热身之后把指针移到对话区中央（in）或窗口外的屏幕角落（out），量完放回。结果带 `pointerInWindow`：指针在窗口里时 AppKit 每帧还要重设光标，两种条件的数不能混着比。
  - 定预算以 `hid` 加 `in` 为准；旧新各跑三遍、交替，同口径比指令数、p90/p99、超 6.9ms 与 16ms 的圈数、掉帧。
- Time Profiler：`xctrace record --template 'Time Profiler' --attach <pid>`，pid 用 `pgrep -f` 在后台启动后取。

### 交互预算

预算表只在 `InteractionBench.budgets`，指标的定义在 `InteractionBench` 与 `Probes.swift` 的注释里，跑法在 `perf-mac.sh` 头注释里；和预算比的数至少跑两遍取中位数。

Mac 的 `-CuePadInteractOnly 项,项` 只量列出的几项，前后对比省下整套流程（列的项之间要自己够得着，如开编辑页配收编辑页）。

## 崩溃诊断

`Diagnostics` 把 MetricKit 交来的诊断存在资料库目录下（隔离库不订阅）。真机崩溃拿不到栈时，请用户从设置的"上次崩溃"里"导出诊断"发来（摘要未符号化，靠 dSYM 还原）。验收：`-CuePadSampleCrash YES` 存一份样例（配 `-CuePadCrashSheet YES` 直接打开摘要）。
