# 性能与同步测量

跑法与口径在各脚本头注释；这里只记怎么读数与踩过的坑。

- 渲染服务的开销（`perf idle` 的 `render*`，常驻动效如 `LoopLayer`、头像帧序列都算在那里）：iOS 模拟器的可比；Mac 的是 WindowServer，合成整个屏幕、随别的 App 起伏，只在静置的桌面上用 `perf ab` 多跑几轮才能比。
- 掉帧数是主线程 display link 的回调间隔，反映主线程跟不跟得上，不是实际交出的帧率；以 Instruments 的 Animation Hitches 为准。iOS 模拟器不支持它，用 `xc.sh rec` 逐帧或应用内探针。屏幕外（`-CuePadOffscreen`）display link 不走，只用于布局与日志类场景。
- Instruments：录 Release 构建给 `xc.sh perf`（含 `idle`、`launch`）加 `CUEPAD_TRACE=<模板>`，脚本按 PID 录（存哪见各脚本头注释）；掉帧用 `CUEPAD_TRACE='Animation Hitches' xc.sh perf mac 1 -CuePadInteractOnly 项`，只录量的那一段（脱离脚本单独录这个模板会写出几十 GB）。Debug 实例 `xc.sh run mac` 拿 PID 再 `xctrace record --attach <PID>`（按名字或 bundle id 会认到正式版）。SwiftUI 模板 `--attach` 没有数据，要 `--launch` 一份换了 bundle id 并重签名的副本；`--launch` 的进程结束后可能停在暂停状态，按 PID 结束。
- 冷启动用真实库的只读副本当种子时，副本的 `preferences.plist` 里放一条窗口位置（`plutil -insert "NSWindow Frame main" -string "<x y 宽 高 屏x 屏y 屏宽 屏高>"`）：没记过位置的库少排一遍，量得偏轻。开发机上 LaunchServices 登记着上千份删掉了的本机构建，查找占冷启动主线程一成多，正式版也一样付，不是回归。
- 量 Cue 值班的开销：库里要有 Cue 运行在这台的设置（`cueProfile` 的 `hostID` 是 `mac-<名>`、运行时 pi，配 `-CuePadHost <名>`），大脑换成 `-CuePadCueBrain apple/scripts/cue-brain-stub.py`，会话的动静由说桥协议的假扩展给（[verify.md](verify.md)「通知」）。隔离实例的本机标识是 `mac-isolated`，真实库副本里记给这台的请求、会话与值班它都当别台的：在副本上量先把 `hostID` 改成 `mac-<名>`；副本没带 `Cue/keeper.json`，第一次值班会当刚启用醒一次。

## 交互预算

- 点击回合的时长随那一刻的频率能差一倍（空闲后的第一下性能核常没升频），同列的指令数不随它变。
- `-CuePadInteractOnly 项,项`（跟在 `xc.sh perf <mac|ios> 次数` 之后）只量列出的几项；列的项之间要自己够得着（开编辑页配收编辑页）。
- 5 轮全量约 35 分钟，超过任务时限（`_lock.sh` 的 HOLD_LIMIT）：`CUEPAD_TEST_TIME_LIMIT=3600 xc.sh perf mac 5`。
- 冷启动进 Cue 页要量真实大小的对话：`CUEPAD_PERF_SEED=<真实库的只读副本> xc.sh perf ios 5 -CuePadInteractOnly "冷启动·Cue 页"`（副本先用这个构建打开一次，免得量进升级库结构）。
- 宽屏阈值那几项（`InteractionBench+Wide`）判不对时看 `interact.jsonl` 那一行的 `timeline` 与 `unexpected`（`WideWatch`）：有「窗宽变成…（要的是…）」就是测量之外有人改了窗口，后面跟调用栈；只有状态变化就看这一步里变的是哪一样。

### 开合的逐帧量法

宽屏开合（做法在 [ui.md](ui.md)「宽屏开合」）量两样，缺一不可：

- 主线程开销：`xc.sh perf ab <旧> <新> 3 mac 1 -CuePadInteractOnly "侧栏收起,侧栏展开,Cue 收起,Cue 放回"`，再加宽屏阈值那几项（`宽屏收窄·…`、`宽屏展开·…`、`宽屏反向·…`、`Cue 收钮·…`、`Cue 露出·…`）。比指令、掉帧与点击那一圈之外最长的一圈（`interact.jsonl` 的 `heavy`）；点击那一圈有时拆成两圈，加起来才是它。「宽屏反向」的每帧位移在大库上常读成 128 或 256，是主线程忙时漏采，跳没跳以录屏为准。
- 屏上每样东西是不是连续地走：`xc.sh rec mac -- -CuePadDemo YES … -CuePadWindowSize 1512x900 -CuePadSidebarCycle YES`（`fast` 中途反向；`-CuePadRightCycle` 开合 Cue；`-CuePadWideReverse <组合>` 跨临界宽），再用 `apple/scripts/frame-track.py` 逐帧量左对齐、居中、靠右三类东西的左缘。每段单调、没有反向步才算过；`fast` 看按下前后位置是否连着。会话、看板、项目三页各量收起、展开与 `fast`。
  - 最大单步只在动的那几段里取（录屏最后几帧是实例退出）；看板卡标题会换行、模板会认错，看板用列头与第四列；`-CuePadWideReverse` 改窗口宽的那一帧尺寸不同，不算。
  - 某一步特别大时比同一帧里别的东西走到曲线的哪儿：都一样就是合成那一帧晚交（负载高时偶有），不是错位。
- iPad 同样录：`xc.sh rec ipad -- -CuePadDemo YES -CuePadQuiet YES -CuePadLandscape YES … -CuePadSidebarCycle YES`。横屏才放得下会话条；iPad Pro 11 横屏会话条与 Cue 同开放不下，量会话条开合加 `-CuePadCue shut`。

### 主区换宽一次

量法：`xc.sh perf mac 1 -CuePadInteractOnly "换宽·会话页,换宽·看板,换宽·项目页"`。隔着构建与负载能差一成，前后对比只用 `perf ab` 看指令。

## 同步测量

两台设备间同步的时延与开销只用 `apple/scripts/sync-bench.py`。

- 模拟云不模拟：cloudd 的排队（实测 p50 5 毫秒、p95 0.1 秒）、改记录冲突、真网络的抖动；限流只在 `throttle` 场景里注入。
  所以它给的绝对值偏乐观，看前后差；和真环境差多少以确认运行为准。
- 灵动岛（`island`）：模拟器上量不到推送本身：`simctl push` 不收只有 content-available 的推送（"no user visible content"），
  可见推送由系统直接出通知、不经 App；本机构建 ad-hoc 签名不带推送权限，系统不在后台叫起它（"doesn't declare the proper UIBackgroundMode"），补签推送权限的包起不来（要描述文件）。
  推送到达、后台叫醒、岛画到锁屏上只能真机验。
- 量不了的：手机真的被挂起、App Nap 与系统节流（直接起的进程不被节流；隐藏的 Mac 实例窗口仍在画，`parkWhileUnseen` 不生效）；真机的网络。
- 限流（`throttle`）：模拟云的限流不拦门铃，正式版被限时门铃也会断、退回轮询，要看这种就加 `SYNC_BENCH_RELAY=0`。
- 常驻开销（`idle`）：实例是 Debug 构建、带界面，同步只占进程开销的一小部分，前后对比看指令与请求数。

### 真 CloudKit

- CloudKit 的限流按设备与容器算（日志里 `Device throttle: container=…`，HTTP 429）：测量实例与这台的正式版共用一份：几个检出接连测量时正式版每 10 分钟被拒 300–490 次（平时个位数），拖慢用户自己的同步。
- 前提：这台 Mac 按 Provisioning UDID（`system_profiler SPHardwareDataType`，不是 Hardware UUID）登记过，装了「CuePad macOS Development」描述文件：`xc.sh provision device <UDID> <名称> MAC_OS`，再 `xc.sh provision profiles`。
- 两个实例共用这台的 cloudd、排同一个队，尾部时延比真机大；CloudKit 的字节（`idle`）不含 TLS 与 HTTP 头；nettop 量不了：流量都记在 cloudd 名下，和正式版的混在一起。
