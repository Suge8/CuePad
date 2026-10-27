# 性能与同步测量

三个入口都是 Release 构建、每次全新进程、多次取中位，跑法与口径在各脚本头注释，和交互预算比的要占前台（[verify.md](verify.md)「占前台」）：交互是 `xc.sh perf mac|ios`，静置与常驻开销是 `xc.sh perf idle mac|ios`，Mac 冷启动到首屏与能交互是 `xc.sh perf launch mac`。前后对比是旧新两个检出交替跑同一条命令，以指令数与唤醒为准：机器忙时帧间隔、CPU 时间、能耗都会被别的进程拖歪。`xc.sh` 每条命令结束打一行用时（排队、编译、其余）与那一刻的 1 分钟负载，时间花在哪、机器忙不忙看它。

- 常驻动效（`LoopLayer` 的循环、头像帧序列）的开销在渲染服务里，App 进程看不到：`perf idle` 同一窗口另记渲染服务的 `render*`（口径在 `rusage.py` 头注释）。头像的眨眼张望每一下都要合成几帧，静置开销随次数涨（`CueSprite` 头注释）。iOS 模拟器是它的 backboardd，CPU、指令、唤醒都有，含模拟器的系统界面，基线相同、前后可比；
  Mac 是 WindowServer，不提权只读得到 ps 的累计 CPU，合成整个屏幕、随别的 App 起伏，机器上有别的东西在动时几秒的波动盖过 CuePad 自己的几十毫秒，只在静置的桌面上前后交替多跑几次才能比。
- 掉帧数是主线程 display link 的回调间隔，反映主线程跟不跟得上，不是实际交出的帧率；以 Instruments 的 Animation Hitches 为准。iOS 模拟器不支持 Animation Hitches，用 `xc.sh rec` 逐帧或应用内探针。屏幕外（`-CuePadOffscreen`）display link 不走，只用于布局与日志类场景。
- Instruments：Release 用 `CUEPAD_TRACE=<模板>` 跟着 perf 录；Debug 实例 `xc.sh run mac` 拿 PID 再 `xctrace record --attach <PID>`。按名字或 bundle id 认 CuePad 会认到正式版。
- SwiftUI 模板 `--attach` 没有数据：`--launch` 一份换了 bundle id 并重签名的副本。`Animation Hitches` 模板单独录会写出几十 GB，不用；`--launch` 的进程结束后可能停在暂停状态，按 PID 结束。
- 冷启动在真实库的只读副本上量（`CUEPAD_PERF_SEED`），副本的 `preferences.plist` 里放一条正式版都有的窗口位置（`plutil -insert "NSWindow Frame main" -string "<x y 宽 高 屏x 屏y 屏宽 屏高>"`）：没记过位置的库少排一遍按记下的大小摆窗口，量得偏轻。
  AppKit 起来时为本 App 查几遍 LaunchServices，同一个 bundle id 登记过的每一份都要比对；开发机上登记着上千份删掉了的本机构建（`lsregister -dump` 里 `Bundle node not found on disk`），这几次查找占冷启动主线程的一成多，正式版也一样付。
- Cue 值班的开销：库里要有 Cue 运行在这台的设置（`cueProfile` 的 `hostID` 是 `mac-<名>`、运行时 pi，配 `-CuePadHost <名>`），大脑换成 `-CuePadCueBrain apple/scripts/cue-brain-stub.py`，会话的动静由说桥协议的假扩展给（[verify.md](verify.md)「通知」）。
  隔离实例的本机标识是 `mac-isolated`（`-CuePadHost` 可换，不能是这台的硬件标识），真实库副本里记给这台的请求、会话与 Cue 值班它都当别台的。在副本上量值班先把 `cueProfile` 的 `hostID` 改成 `mac-<名>`；副本没带 `Cue/keeper.json`，第一次值班会当刚启用醒一次。

## 交互预算

预算表在 `InteractionBench.budgets`，指标定义在它与 `Probes.swift` 的注释里。和预算比的数在前台量、至少跑两遍取中位；前台测量不独占机器，别的编译、测试照常在跑，看 `xc.sh` 结束那行用时里的 1 分钟负载：高于 CPU 核数（`sysctl -n hw.ncpu`）时帧、掉帧与回合时长不可比，只比指令数。点击回合随机器那一刻的频率差到一倍（空闲后的第一下性能核常没升频）：同列的指令数不随它变，GHz 低的那几次就是慢在频率上。

- `-CuePadInteractOnly 项,项`（跟在 `xc.sh perf <mac|ios> 次数` 之后）只量列出的几项，前后对比省下整套流程；列的项之间要自己够得着（开编辑页配收编辑页）。
- 冷启动进 Cue 页要量真实大小的对话：`CUEPAD_PERF_SEED=<真实库的只读副本> xc.sh perf ios 5 -CuePadInteractOnly "冷启动·Cue 页"`（副本先用这个构建打开一次，免得每次都量进升级库结构）。项名带空格要加引号。

## 同步测量

两台设备间同步的时延与开销只用 `apple/scripts/sync-bench.py`（场景、用法、延迟模型的数值与出处在头注释，每段的定义在 `_sync_scenes.py`）。
同一台 Mac 上两个隔离实例：A 是有在线会话、Cue 在值班的 Mac，B 代替手机（拉取按手机那档，进后台、回前台走手机的入口）。两端只听脚本的命令、打点，节奏只在脚本里。

- 两种云。默认是模拟云（`SharedCloud`）：两个实例共用这次运行的一个 SQLite 文件当同步区，同步代码照真的跑，每个请求按开发环境实测的分布睡一段。
  测的是我们自己代码的调度与排队，不连 iCloud。前后对比一律用它。
  `SYNC_BENCH_CLOUD=real` 连 CloudKit **开发环境**，只做少量确认（下面「真 CloudKit」）。
- 模拟云不模拟：cloudd 的排队（实测 p50 5 毫秒、p95 0.1 秒）、改记录冲突、真网络的抖动；限流只在 `throttle` 场景里注入；门铃照常连正式中转（房间按这次运行的密钥，不与别的运行重合）。
  所以它给的绝对值偏乐观，看前后差；和真环境差多少以确认运行为准。
- 前后对比：`sync-bench.py ab <旧检出> <新检出> <轮数> <场景> [参数]`，交替跑、出 p50 / p95 与样本数的对比表，附每边运行期间的 1 分钟负载。两个检出都要含测量打点与模拟云（`DebugScene+SyncBench.swift`、`SharedCloud`）。
- 锁：模拟云的运行互相排队（`SIM_LOCK`，不抢 CPU）；连 CloudKit 的运行与探针共用 `LOCK`（都在 `sync-bench.py`）。构建在锁外。
- 口径：时刻都是同一台机器的墙钟。写下取记录的创建时刻；已发出、入库、回执取实例读到库里变化的那一刻（库的订阅送到主线程）；上屏取页面订阅拿到新值后那一次界面提交（`SyncBench.Watch.observed`，两端开着 Cue 页）。
  冷启动从起进程算。Cue 自己说的话被服务器收下不叫醒说的话的订阅，Mac→手机这一段只量到手机入库。
- 门铃不通：`SYNC_BENCH_RELAY=0` 两端都不连中转（`-CuePadSyncBenchNoRelay`），不停正式中转。
- 断网（`offline`）：只让手机那个实例的请求当场以 -1009 失败、门铃断开（`CloudOutage`），不碰机器的网络。恢复时默认替路径监视器报一次网络回来（同真断网）；`nopath` 是路径一直可用、只是云连不上的那种恢复。
- 灵动岛（`island`）：iPhone 模拟器里量 App 这一侧"拉到的话入库 → 实时活动换内容"。模拟器上量不到推送本身：`simctl push` 不收只有 content-available 的推送（"no user visible content"），
  可见推送由系统直接出通知、不经 App；本机构建 ad-hoc 签名不带推送权限，系统不在后台叫起它（"doesn't declare the proper UIBackgroundMode"），补签推送权限的包起不来（要描述文件）。
  推送到达、后台叫醒、岛画到锁屏上只能真机验（docs/sync.md「推送拉起被划掉的 App」）；拉取那段由 Mac 上的替身手机量（`send`、`fg`）。
- 量不了的：手机真的被挂起、App Nap 与系统节流（直接起的进程不被节流；隐藏的 Mac 实例窗口仍在画，`parkWhileUnseen` 不生效）；真机的网络。
- 限流（`throttle`，只在模拟云）：窗口内云照设备限流回 429 带 Retry-After，两个实例共用一份（同一台设备）；按云记下的每个请求数窗口内的拉取、上传与没守自己收到的 Retry-After 的次数。
  模拟云的限流不拦门铃，正式版被限时门铃也会断、退回轮询，要看这种就加 `SYNC_BENCH_RELAY=0`。
- 撞版本探针（`versions`，不进总表）：App 紧循环改一张卡、这个检出的命令行同时逐条改同一张，库里的审计触发器记每次提交的版本，数不比上一版大的提交。
- 常驻开销（`idle`）：实例是 Debug 构建、带界面，同步只占进程开销的一小部分，前后对比看指令与请求数。

### 真 CloudKit

- CloudKit 的限流按设备与容器算（日志里 `Device throttle: container=…`，HTTP 429）：测量实例与这台的正式版共用一份。2026-10-26 01:20 起几个检出接连测量，
  正式版每 10 分钟被拒 300–490 次（之前个位数），测量在拖慢用户自己的同步。所以真 CloudKit 只做确认，脚本守着冷却、时限与请求上限（`sync-bench.py` 头注释）；
  运行期间实例被限的次数记进结果，报告里标为不可信。
- 前提：这台 Mac 按 Provisioning UDID（`system_profiler SPHardwareDataType`，不是 Hardware UUID）登记过，装了「CuePad macOS Development」描述文件：`provision.py device <UDID> <名称> MAC_OS`，再 `provision.py profiles`。
- 只碰开发环境：隔离库连 iCloud 要 Debug 构建、`-CuePadCloudKit YES`、Development 签名三样都在（`DebugScene.syncsIsolatedLibrary`；模拟云也走这三样，只是不建 CKContainer）。
- 库按检出留在 `REAL_LIBS`（`_sync_run.py`）接着用：开发区里留着别的调试数据（演示会话、老版本写的卡片），全新的库第一次要拉完它们。对会话说话只对 A 的会话（`mac-bench-a`）。
- 两个实例共用这台的 cloudd、排同一个队，尾部时延比真机大；CloudKit 的字节（`idle`）不含 TLS 与 HTTP 头；nettop 量不了：流量都记在 cloudd 名下，和正式版的混在一起。
