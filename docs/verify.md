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

### 交互预算

预算表只在 `InteractionBench.budgets`，指标的定义在 `InteractionBench` 与 `Probes.swift` 的注释里，跑法在 `perf-mac.sh` 头注释里；和预算比的数至少跑两遍取中位数。

Mac 的 `-CuePadInteractOnly 项,项` 只量列出的几项，前后对比省下整套流程（列的项之间要自己够得着，如开编辑页配收编辑页）。

## 崩溃诊断

`Diagnostics` 把 MetricKit 交来的诊断存在资料库目录下（隔离库不订阅）。真机崩溃拿不到栈时，请用户从设置的"上次崩溃"里"导出诊断"发来（摘要未符号化，靠 dSYM 还原）。验收：`-CuePadSampleCrash YES` 存一份样例（配 `-CuePadCrashSheet YES` 直接打开摘要）。

## 同步延迟实测

要回答的问题：Mac 的 2 秒主动拉取（`ZoneChangePuller`）能不能放慢或删掉，而手机→Mac、Mac→手机不变慢。依据是到达日志（`ArrivalLog`）：别的设备写来、本机在等的记录（投送请求、Pi 会话状态）每到一条记一行（类别 `sync-latency`，Release 里也有），写明经哪条路、比服务器时间晚多少秒、当时设备在什么状态。

- `push`：CKSyncEngine 自己调度的拉取（推送触发，也含启动与周期拉取，所以是推送延迟的上界）。`pull`：主动拉取。`manual`：本机回前台、唤醒时自己调的拉取，不参与推送判断。
- 主动拉取先拿到的，等引擎稍后补拿时再补记一行 push；5 分钟引擎仍没带来记为"推送丢失"；这期间记录已有更新的版本（Mac 领取、执行完又写回）的记为"被取代"——引擎只带来最新版本，旧版本的推送量不到，既不算延迟也不算丢失。
- 每行写了服务器时间（`server`）、本机到达时刻（`at`）和两者之差（`lag`），可以自己复核。起点是服务器时间、终点是本机时钟，误差零点几秒；看几秒量级的 p90 没问题，不要拿它比亚秒。
- 两个偏差要记得：推送延迟是上界（引擎的启动与周期拉取也算进去）；推送丢失只在主动拉取先拿到时才看得见，所以测的时候 Mac 上要有开着的 Pi 会话（主动拉取在跑），否则丢了的请求只会表现为一直没到。很晚才经推送到、又没有主动拉取佐证的记为"积压"，不进分位数，但有积压时分析不会建议删除拉取（120 秒是凭经验定的界线：App 没开期间攒下的记录会远超这个数，正常推送不会）。

### 一次实测（约 10 分钟，25 条请求）

准备：Mac 与 iPhone 用同一个 Apple ID、装带这个埋点的同一个构建；Mac 上的 CuePad 开着，并且在终端里开一个 Pi 会话（让 Mac 的主动拉取处于 2 秒档，才测得到"拉取先到"）；iPhone 用线连着 Mac，解锁、信任这台 Mac。

手机上的操作都是同一个：设置·同步·"测试到 Mac 的连接"，点一次发 5 条，每条等 Mac 回结果再发下一条。

1. Mac 前台（CuePad 窗口在最前）、手机前台 Wi-Fi：点 1 次（5 条）。
2. Mac 后台（点开别的 App）：点 1 次（5 条）。
3. Mac 锁屏（⌃⌘Q）：点 1 次（5 条），然后解锁。
4. Mac 睡眠（菜单·睡眠），等 1 分钟让它真的睡着：点 1 次；第一条会等 60 秒后显示失败，这是预期；然后唤醒 Mac，请求在唤醒后到达（1 条）。
5. 手机后台：Mac 回前台。点 1 次后马上按手机电源键锁屏，等 30 秒再亮屏；做 2 遍（每遍 1 条）。
6. 手机蜂窝：关掉手机 Wi-Fi（Mac 保持 Wi-Fi），前台点 1 次（5 条）；再来 1 遍"点后马上锁屏、等 30 秒"（1 条）。

取数（做完立刻取，日志只留一阵）：

```bash
apple/scripts/xc.sh synclat --last 30m                       # Mac 这一侧：手机→Mac 的请求
sudo log collect --device --last 30m --output ~/Desktop/手机.logarchive   # 手机这一侧（线连着，会要 Mac 密码）
apple/scripts/xc.sh synclat --last 30m --archive ~/Desktop/手机.logarchive # 两侧合在一起
```

手机侧不方便连线时：设置里按住两个音量键加电源键做一次 sysdiagnose，导出后用其中的 `system_logs.logarchive` 代替上面的文件。输出按场景（Mac 前台/后台/锁屏/刚唤醒；手机前台/后台×Wi-Fi/蜂窝）列样本数、推送 p50/p90/最大、丢失率、拉取先到的比例与提前多少。这 25 条只够看一眼；之后正常用一两天，每次别的设备写来的请求都会自己攒样本，再跑同一条命令，样本到 20 条以上再下结论。

### 决策门槛

看"手机→Mac（请求）"的合计行：
- 推送 p90 ≤ 2 秒且丢失 < 1%（样本 ≥ 20）：Mac 主动拉取放到 30–60 秒，或删掉。
- 推送 p90 > 5 秒或丢失 > 5%：保持 2 秒。
- 介于两者之间：保守放到 10 秒，再测一轮；不要删。
- 锁屏、刚唤醒这类场景的推送明显慢于总体：主动拉取在这些场景有价值，不删，最多放慢。
- "被取代"的请求占比超过 1%：只放到 10 秒，不删；超过 20%：保持 2 秒。被取代的是主动拉取先拿到、Mac 领取执行写回之后引擎只剩最新版本的请求，推送延迟量不到——它们恰恰是主动拉取在起作用的请求，不能算作"推送可靠"。占比高时，先让它降下来再评估（例如实测时让 Mac 晚一点领取），不是在门槛里把它们排除。
- 门槛的判断有回归用例：`python3 apple/scripts/synclat_test.py`。

"Mac→手机（结果）"同理，决定的是手机那边的 2 秒拉取（`SyncPoller.Cadence.phone`）。
