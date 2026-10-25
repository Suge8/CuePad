# 性能与同步测量

两个入口都是 Release 构建、每次全新进程、多次取中位，跑法与口径在各脚本头注释，和交互预算比的要占前台（[verify.md](verify.md)「占前台」）：交互是 `xc.sh perf mac|ios`，静置与常驻开销是 `xc.sh perf idle mac|ios`。前后对比是旧新两个检出交替跑同一条命令，以指令数与唤醒为准：机器忙时帧间隔、CPU 时间、能耗都会被别的进程拖歪。

- 掉帧数是主线程 display link 的回调间隔，反映主线程跟不跟得上，不是实际交出的帧率；以 Instruments 的 Animation Hitches 为准。iOS 模拟器不支持 Animation Hitches，用 `xc.sh rec` 逐帧或应用内探针。屏幕外（`-CuePadOffscreen`）display link 不走，只用于布局与日志类场景。
- Instruments：Release 用 `CUEPAD_TRACE=<模板>` 跟着 perf 录；Debug 实例 `xc.sh run mac` 拿 PID 再 `xctrace record --attach <PID>`。按名字或 bundle id 认 CuePad 会认到正式版。
- SwiftUI 模板 `--attach` 没有数据：`--launch` 一份换了 bundle id 并重签名的副本。`Animation Hitches` 模板单独录会写出几十 GB，不用；`--launch` 的进程结束后可能停在暂停状态，按 PID 结束。
- Cue 值班的开销：库里要有 Cue 运行在这台的设置（`cueProfile` 的 `hostID` 是 `mac-<名>`、运行时 pi，配 `-CuePadHost <名>`），大脑换成 `-CuePadCueBrain apple/scripts/cue-brain-stub.py`，会话的动静由说桥协议的假扩展给（[verify.md](verify.md)「通知」）。
  隔离实例的本机标识是 `mac-isolated`（`-CuePadHost` 可换，不能是这台的硬件标识），真实库副本里记给这台的请求、会话与 Cue 值班它都当别台的。在副本上量值班先把 `cueProfile` 的 `hostID` 改成 `mac-<名>`；副本没带 `Cue/keeper.json`，第一次值班会当刚启用醒一次。

## 交互预算

预算表在 `InteractionBench.budgets`，指标定义在它与 `Probes.swift` 的注释里。和预算比的数在前台量、至少跑两遍取中位。点击回合随机器那一刻的频率差到一倍（空闲后的第一下性能核常没升频）：同列的指令数不随它变，GHz 低的那几次就是慢在频率上。

- `-CuePadInteractOnly 项,项`（跟在 `xc.sh perf <mac|ios> 次数` 之后）只量列出的几项，前后对比省下整套流程；列的项之间要自己够得着（开编辑页配收编辑页）。
- 冷启动进 Cue 页要量真实大小的对话：`CUEPAD_PERF_SEED=<真实库的只读副本> xc.sh perf ios 5 -CuePadInteractOnly "冷启动·Cue 页"`（副本先用这个构建打开一次，免得每次都量进升级库结构）。项名带空格要加引号。

## 同步测量

两台设备间同步的时延与开销只用 `apple/scripts/sync-bench.py`（场景、用法与环境变量在头注释，每段的定义在 `_sync_scenes.py`），只经 CloudKit **开发环境**。
同一台 Mac 上两个隔离实例：A 是有在线会话、Cue 在值班的 Mac，B 代替手机（拉取按手机那档，进后台、回前台走手机的入口）。两端只听脚本的命令、打点，节奏只在脚本里。

- 前提：这台 Mac 按 Provisioning UDID（`system_profiler SPHardwareDataType`，不是 Hardware UUID）登记过，装了「CuePad macOS Development」描述文件：`provision.py device <UDID> <名称> MAC_OS`，再 `provision.py profiles`。
- 只碰开发环境：隔离库连 iCloud 要 Debug 构建、`-CuePadCloudKit YES`、Development 签名三样都在（`DebugScene.syncsIsolatedLibrary`）。
- 全机测量锁 `/tmp/cuepad-sync-measure.lock`：每次跑都先拿（构建在锁外），几个检出的测量不同时跑、不共用 cloudd 互相干扰。
- 前后对比：`sync-bench.py ab <旧检出> <新检出> <轮数> <场景> [参数]`，交替跑、出 p50 / p95 与样本数的对比表，附每边运行期间的 1 分钟负载。两个检出都要含测量打点（`DebugScene+SyncBench.swift`）。
  同一时段、同一网络交替跑才可比；看中位数，尾部受共用的 cloudd 排队影响（一个操作慢时两个实例排在后面的一起等），比真机大。
- 口径：时刻都是同一台机器的墙钟。写下取记录的创建时刻；已发出、入库、回执取实例读到库里变化的那一刻（库的订阅送到主线程）；上屏取页面订阅拿到新值后那一次界面提交（`SyncBench.Watch.observed`，两端开着 Cue 页）。
  冷启动从起进程算。Cue 自己说的话被服务器收下不叫醒说的话的订阅，Mac→手机这一段只量到手机入库。
- 门铃不通：`SYNC_BENCH_RELAY=0` 两端都不连中转（`-CuePadSyncBenchNoRelay`），不停正式中转。
- 量不了的：手机真的被挂起、App Nap 与系统节流（直接起的进程不被节流；隐藏的 Mac 实例窗口仍在画，`parkWhileUnseen` 不生效）；推送与实时活动（模拟器登不了 iCloud）；真机的网络。
- 常驻开销（`idle`）：实例是 Debug 构建、带界面，同步只占进程开销的一小部分，前后对比看指令。CloudKit 的字节不含 TLS 与 HTTP 头。nettop 量不了：CloudKit 的流量都记在 cloudd 名下，和正式版的混在一起。
- 开发区里留着别的调试数据（演示会话、老版本写的卡片），全新的库第一次要拉完它们，算在预热里；对会话说话只对 A 的会话（`mac-bench-a`）。
