# 验收与测量

## 视觉验收

`xc.sh shot mac` 直接启动产物里的可执行文件并记下它的 PID（不经 LaunchServices 激活，不抢焦点；上次中断遗留的实例只按记下的 PID 结束），按该 PID 找窗口后只截该窗口（首次需给终端授予屏幕录制权限），以 SIGTERM 退出。`shot ios` / `shot ipad` 构建 → 模拟器安装启动 → 截图 → 终止。`--` 之后是 App 启动参数：

```bash
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark
```

- Debug 构建认一组启动参数，完整列表与含义只写在 `App/Sources/UI/Debug/DebugScene.swift`、`DebugScene+iOS.swift` 的文档注释里；设置项可直接覆盖（`-theme dark`）。产品代码只经 `DebugHooks` 碰调试画面，不认识 `DebugScene`、不写 `#if DEBUG`。调试键不写进偏好域：`UserDefaults.standard` 是真实的 `com.sugeh.cuepad`，测量里要换的值（如搜索词）放内存（`DebugScene.searchOverride`），预填的搜索词只认启动参数。
- `CUEPAD_SHOT_LIBRARY` 换库目录（默认 `.derived/library`）。截图不靠固定等待：Debug 构建摆好画面后写下就绪标记（`DebugScene.signalReady`），`shot` 等它出现再截。
- Pi 目录同样隔离，截图不含 `~/.pi` 的会话。隔离的 Pi 目录里没装扩展，侧栏底部出现"连接 Pi"征求同意是正确状态；不要它时传 `-piExtensionDeclined YES`。
- `settings`、`menubar` 画面把设置窗口、菜单栏面板的内容放进主窗口拍，因为只截主窗口。
- 窗口位置与尺寸会被系统记住（`NSWindow Frame main`），截图尺寸以上次为准；恢复默认：`defaults delete com.sugeh.cuepad "NSWindow Frame main"`。
- 布局反馈环压力：`apple/scripts/layout-stress.sh`，场景与判定见脚本头注释；`--inject-loop` 自检检测器。界面侧的约束见 [ui.md](ui.md)。

## 性能测量

入口只有 `apple/scripts/perf-mac.sh <cold|scenarios|interact> [次数]`，各模式量什么见脚本头注释，场景与指标在 `App/Sources/UI/Debug/` 的 `*Bench.swift`。iOS 的单次交互是 `apple/scripts/perf-ios.sh [次数]`（iPhone 模拟器先重启、演示库、每次全新进程，首次与再次分开；长按菜单要 `axe` 真按；带 DEBUG 条件的 Release，只为留下测量代码；有一次没量完就整次失败）：模拟器的合成与 GPU 不同于真机，只看主线程 CPU 与指令数；首次数里有模拟器才有的 Swift 一致性查找，要在真机上用 Instruments 复核。方法与坑：

- 前后对比以进程执行的指令数（`instructionsM`）为准：机器忙时帧间隔和 CPU 时间都会被别的进程拖歪。旧新两个构建交替各跑三遍取中位数。悬停类场景要窗口在前台才有指针事件，有的轮次整项几乎没有工作量（指令数低一个量级），比较前先剔掉。
- 掉帧与动画类指标必须在前台量：AppKit 的动画只在前台跑，前台每次几何变化还要重算鼠标跟踪区，后台量的数字偏乐观（`interact` 自己把实例调到前台，其余场景先把自己启动的实例调到前台，会抢一下焦点，集中批量跑）。窗口还得在屏幕上：放到屏幕外（`-CuePadOffscreen`）时 display link 不走，屏幕外只用于布局与日志类场景。
- 帧间隔的口径是主线程上 display link 两次回调之间的时间，反映主线程跟不跟得上，不是画面实际交出的帧率；是否真的掉帧以 Instruments 的 Animation Hitches 为准。Animation Hitches 在 iOS 模拟器上不支持，iOS 端用模拟器录屏逐帧或应用内每帧探针。
- 用真实库副本测切会话 / Agent 整页时：副本里会话索引的路径指向 `~/.pi/agent/sessions`，隔离的 Pi 目录里没有这些文件时启动清理会把已结束的会话记录全删掉。先把副本里的路径改到隔离 Pi 目录下（`UPDATE piSessions SET path = replace(path, …)`），再让该目录的 `sessions` 符号链接指向真实会话目录（只读）。"点开后对话区空白"只在会话在线时出现，要先用 `pi-live.py` 把库里的会话连到桥上。
- Instruments：用 Release 优化构建并保留测量代码（`xcodebuild -configuration Release … 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'`）。
- `xctrace record --template 'Time Profiler' --attach <pid>`；`--launch` 按 bundle id 找进程，机器上有别的 CuePad 时报 ambiguous。每项场景包在 os_signpost（名 `scenario`）里，按它切时间窗。
- SwiftUI 模板用 `--attach` 没有数据，要 `--launch` 一份换了 bundle id 的 App 副本（复制后改 `CFBundleIdentifier` 并重签名）；视图更新表与 hitch 表（`hitches`、`hitches-updates`、`hitches-renders`、`hitches-gpu`）都在里面。
- `Animation Hitches` 模板单独录会写出几十 GB，别用；`--launch` 的进程结束后可能停在暂停状态，按它的 PID 结束。

### 交互预算

预算表只在 `InteractionBench.budgets`，按交互类型定目标；没达到的项如实报超预算，不改预算迁就。有一项超预算脚本就以 1 退出。
- 口径：前台、Release 构建（带 DEBUG 条件，只为留下测量代码）、演示库与大库各量一遍、每次全新进程（首访就是首访）、各进程取中位数（默认三遍，至少两遍）。
- 指标：点击回合（动作发出到主线程第一次回到空闲，主线程 CPU 毫秒，只取第一圈 ≥2ms 的 run loop；CPU 时间不随机器忙闲变，墙钟与掉帧会）与动作后 800ms 内的掉帧次数。
- 动作是点击与快捷键最终调用的工作区方法，不含事件投递（1～5ms）。
- 两端同一份探针与指标键名（`Debug/Probes.swift`：每圈主线程 CPU 与墙钟的起点都在动作发出的那一刻，动作之前那一圈的工作不算进点击回合；指令数是进程在这 800ms 里执行的）。Mac 的 `-CuePadInteractOnly 项,项` 只量列出的几项，前后对比省下整套流程（列的项之间要自己够得着，如开纸页配收纸页）。

## 崩溃诊断

`Diagnostics`（iOS 与 Mac 启动时开始）订阅 MetricKit：
- 把系统交来的崩溃、卡死、CPU 与磁盘写入异常诊断（一般在下次启动或隔天）按时间存进资料库目录下的 `Diagnostics/`，只留最近 10 份，不联网、不上传，隔离库不订阅。
- 设置里有诊断时多一行"上次崩溃"，点开看摘要（未符号化，靠 dSYM 还原）并"导出诊断"——真机崩溃拿不到栈时，请用户从这里导出发来。
- 验收：`-CuePadSampleCrash YES` 存一份样例（配 `-CuePadCrashSheet YES` 直接打开摘要）；点通知后的路由用 `-CuePadScene notifytap` 与 `-CuePadColdTap` 看（它们绕过了系统的代理回调）。
