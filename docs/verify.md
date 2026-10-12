# 验收与测量

## 视觉验收

`xc.sh shot` 截图（首次需给终端授予屏幕录制权限）；`--` 之后是 App 启动参数：

```bash
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark
```

- Debug 构建认一组启动参数，完整列表与含义只写在 `App/Sources/UI/Debug/DebugScene.swift`、`DebugScene+iOS.swift` 的文档注释里。产品代码只经 `DebugHooks` 碰调试画面，不认识 `DebugScene`、不写 `#if DEBUG`。调试键不写进偏好域（`UserDefaults.standard` 是真实的 `com.sugeh.cuepad`）：预填的搜索词只认启动参数。
- 截图与 App 测试不抢前台：截图（给了 `CUEPAD_SHOT_READY`）与测试宿主都以后台 App 运行，不进程序坞、不接键盘，截图的主窗口排在所有窗口最后（`DebugHooks.staysInBackground`），按窗口截图照样截得到。要前台的只有量交互与动画（见下文"性能测量"），它会抢焦点、动指针，跑之前先确认用户此刻不在用这台 Mac。
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

### 交互预算

预算表只在 `InteractionBench.budgets`，指标的定义在 `InteractionBench` 与 `Probes.swift` 的注释里，跑法在 `perf-mac.sh` 头注释里；和预算比的数至少跑两遍取中位数。

Mac 的 `-CuePadInteractOnly 项,项` 只量列出的几项，前后对比省下整套流程（列的项之间要自己够得着，如开编辑页配收编辑页）。

## 崩溃诊断

`Diagnostics` 把 MetricKit 交来的诊断存在资料库目录下（隔离库不订阅）。真机崩溃拿不到栈时，请用户从设置的"上次崩溃"里"导出诊断"发来（摘要未符号化，靠 dSYM 还原）。验收：`-CuePadSampleCrash YES` 存一份样例（配 `-CuePadCrashSheet YES` 直接打开摘要）。
