# 验收与测量

## 视觉验收

`xc.sh shot` 截图（首次需给终端授予屏幕录制权限）；`--` 之后是 App 启动参数：

```bash
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark
```

- Debug 构建认的启动参数只写在 `App/Sources/UI/Debug/DebugScene.swift`、`DebugScene+iOS.swift` 的文档注释里。调试键不写进偏好域（`UserDefaults.standard` 是真实的 `com.sugeh.cuepad`）：预填的搜索词只认启动参数。
- 截图与 App 测试以后台 App 运行，不抢前台（`DebugHooks.staysInBackground`）。要前台的只有量交互与动画（见"性能测量"），它会抢焦点、动指针，跑之前先确认用户此刻不在用这台 Mac。
- 后台窗口里的网页截图不可信：同一次运行里先有内容、过几秒就成了空白，WebKit 自己的快照却一直有内容。看网页预览用快照：`-CuePadWebSnapshot <PNG 路径>`（配 `-CuePadOpenPreview` 打开那一页，载入完存成 PNG）。
- 窗口尺寸用 `-CuePadWindowSize` 定；不给时沿用这个隔离库上次记下的位置与尺寸。
- Mac 截图、录屏只认窗口本身的像素尺寸：调度中心、台前调度开着时系统把窗口缩小显示，截到的是缩小的画面，`xc.sh` 比对尺寸后报错不出图——关掉再拍。
- Mac 的系统菜单（项目切换、右键菜单）：`xc.sh run mac -- … -CuePadClick x,y`（或 `-CuePadRightClick`）让实例自己点开，再按窗口截菜单那扇窗（`screencapture -l`，窗口号从 CGWindowList 按 PID 取），截完按 PID 结束。会到前台。
- 动效与状态切换录屏看：`xc.sh rec ios|ipad|mac <out.mov> -- …`（Mac 按窗口录，挡着的窗口与系统录屏标记不进画面）；会话状态切换配 `-CuePadCycle YES`（演示会话循环走过各种状态，参数见 `DebugScene.swift`）。冷启动的首屏给 `CUEPAD_REC_LAUNCH=1`，从启动前开录；配 `-CuePadSync arrive` 看启动后拉到一批别的设备写下的话时页面怎么变。录屏只在画面变时出帧，逐帧看用 `ffmpeg -i out.mov -fps_mode vfr …` 按真实时刻取。逐帧铺成一张图再看：`ffmpeg -i out.mov -vf "fps=8,crop=宽:高:x:y,tile=8x2" -frames:v 1 strip.png`（坐标是录屏的像素）。
- 裁图、缩放用系统自带的 `sips`（`sips -c 高 宽 --cropOffset y x`、`sips -z 高 宽`），本机没装 ImageMagick。
- 模拟器（选哪台、启停、隔离库）只经 `xc.sh`，规则见它与 `_sim.sh` 的头注释。
- 布局反馈环压力：`apple/scripts/layout-stress.sh`，场景与判定见脚本头注释。
- 验收用户装着的版本前，核对装着的 App 构建号（`defaults read ~/Applications/CuePad.app/Contents/Info CFBundleVersion`）与 `~/.pi/agent/extensions/cuepad-bridge.ts` 里的 `EXTENSION_VERSION` 是否就是要验的那一版：旧包或旧扩展上验出的结论不算数。

## 真实数据复现

首帧、滚动、输入类问题，在演示库上好了不算修好，要在用户真实库的只读副本上复现并验证：演示库的条数、正文长短与图片都和真实库差得远。

```bash
mkdir -p /tmp/cuepad-copy
sqlite3 -readonly "<库目录>/cuepad.db" ".backup /tmp/cuepad-copy/cuepad.db"   # 库目录见 LibraryLocation
cp -R "<库目录>/Attachments" /tmp/cuepad-copy/   # 要看图时
CUEPAD_LIBRARY_DIR=/tmp/cuepad-copy …
```

`.backup` 走 SQLite 的在线备份，正式版开着库也能拷出一致的一份；直接 `cp` 会漏掉 WAL 里还没落盘的写入。副本里有用户的私人内容，验完删掉 `/tmp/cuepad-copy`。

## 交互验收（Mac）

点菜单、输入、看状态变化先读 better-computer-use skill，用 `bcu` 操作 `xc.sh run mac` 起的隔离实例：实例在后台，bcu 按无障碍和进程投递动作，不抢用户的前台和指针。改了菜单、输入框、浮窗、提示这类接线就走一遍：流程测试证明不了它们接上了。

```bash
pid=$(apple/scripts/xc.sh run mac -- -CuePadDemo YES -CuePadScene projectagent -CuePadProject 圆桌)
bcu find-roots --app CuePad    # 用 "pid $pid" 那一行的 window 根
```

- 机器上常开着别的 CuePad（用户的正式版、并行 agent 的）：只按 PID 认根，按应用名找窗口会点到用户的；验完 `kill -TERM $pid`。
- `projectagent` 场景带演示会话（另一台 Mac 上在线的），任务、步骤与会话的绑定都有。
- SwiftUI 输入框用 `setText` 只改了无障碍的值、进不了绑定（不保存）：先 `click` 再 `typeText`（状态要 `--image always`）。
- 提示条 2.4 秒就收：要验提示，把 `expect` 写进同一组动作。
- 让 Cue 真跑（看 Mac 的“运行情况”，`-CuePadScene cuerun` 直接开着）：隔离实例里没有登录的大脑，起实例前导出 Claude Code 走 DeepSeek 的变量（同 `ClaudeTestbed`：`ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、空的 `ANTHROPIC_API_KEY`、`ANTHROPIC_MODEL=deepseek-flash`），点启用后在 Cue 页输入框的模型菜单里选 Claude Code 那一组：有这组变量时 Pi 也算登录了、会先被选上，一跑就 401。
- 任务行右键（`click` 带 `"button":"right"`）在后台弹得出菜单；墙上的灵感卡右键被当成点按（打开编辑页），它的操作从编辑页走。
- iOS 没有 Simulator.app 窗口可给 bcu 操作：点按用 `axe tap -x <x> -y <y> --udid <模拟器>`（坐标是点，`xcrun simctl io <模拟器> screenshot` 截图换算；`axe describe-ui` 读不到 SwiftUI 的元素），起画面用 `xcrun simctl launch` 带同一组启动参数。模拟器用 `xc.sh shot` 刚用过的那台（名为 "CuePad <机型> #<号>"，见 `_sim.sh`），不碰别人的；这一池是共用的，别的任务随时会在上面装包重跑，要连续操作就尽快做完。

## 通知（Mac）

- 隔离库默认不发系统通知（只记日志），也不要权限、不装提示音、不设角标：权限、提示音与角标按 bundle id 记，与正式版同一个。验收时给 Debug 启动参数 `-CuePadNotifications YES` 才真发，提示音这时装进真实的 ~/Library/Sounds。
- /tmp 下的构建拿不到通知权限（日志 `Failed to find or validate client`）：复制到 ~/Applications，改掉 `CFBundleIdentifier` 再 ad-hoc 重签名（不和正式版共用通知设置，点通知也不会激活正式版），用 `open -n -g --env …` 带上 AGENTS.md 要的几个目录启动；验完删掉副本，系统设置的通知列表里会留下这个 bundle id。
- 触发：本机会话在 `CUEPAD_PI_SOCKET_DIR` 里放一个说桥协议的假扩展（协议见 CuePi README）切它的状态；Cue 来问用 `-CuePadSampleCue <秒>`（隔离库里 Cue 不值班）。
- 系统要等自己的通知处理（含 Apple 智能摘要）走完才呈现，本机实测有时要 20 秒；横幅 5 秒就收，按横幅要边等边找（`bcu find-roots --app NotificationCenter` 里的 dialog）。
- 实际播了哪个文件看 `systemsoundserverd` 日志里的 `mAudioToken`（通知中心那行 `Playing notification sound` 只有声音名，找不到文件时也照样打，实际播的是系统兜底音）；Dock 角标读 Dock 里这一项的 `AXStatusLabel`。

## 性能测量

测量只有一个入口：单次交互（`-CuePadBench interact`）。`xc.sh perf mac`、`xc.sh perf ios`（独占机器；口径与限制见 `perf-mac.sh`、`perf-ios.sh` 的头注释），场景与指标在 `App/Sources/UI/Debug/InteractionBench.swift`。方法与坑：

- 前后对比以进程执行的指令数（`instructionsM`）为准：机器忙时帧间隔和 CPU 时间都会被别的进程拖歪。旧新两个构建交替各跑三遍取中位数。
- 用户在用这台 Mac 时，给 `CUEPAD_SHOT_READY=<任意路径>` 让 interact 留在后台：指令数照样能做前后对比，帧与掉帧偏乐观、不和预算比。
- 掉帧与动画类指标在前台量：AppKit 的动画只在前台跑，前台每次几何变化还要重算鼠标跟踪区，后台量的数字偏乐观。窗口还得在屏幕上：屏幕外（`-CuePadOffscreen`）display link 不走，只用于布局与日志类场景。
- 掉帧数看的是主线程上 display link 的回调间隔，反映主线程跟不跟得上，不是画面实际交出的帧率；是否真的掉帧以 Instruments 的 Animation Hitches 为准。iOS 模拟器不支持 Animation Hitches，iOS 端用 `xc.sh rec` 录屏逐帧或应用内每帧探针。
- Instruments 用 Release 优化构建并保留测量代码：`xc.sh perf mac` 构建的 `apple/.derived-perf-release` 就是这份。
- `xctrace record --template 'Time Profiler' --attach <pid>`；`--launch` 按 bundle id 找进程，机器上有别的 CuePad 时报 ambiguous。
- SwiftUI 模板用 `--attach` 没有数据，要 `--launch` 一份换了 bundle id 的 App 副本（复制后改 `CFBundleIdentifier` 并重签名）；视图更新表与 hitch 表（`hitches`、`hitches-updates`、`hitches-renders`、`hitches-gpu`）都在里面。
- `Animation Hitches` 模板单独录会写出几十 GB，不用；`--launch` 的进程结束后可能停在暂停状态，按它的 PID 结束。
- 会话页与 Cue 页滚动（Mac，可不碰指针、不抢焦点）：`-CuePadBench chatscroll`，跑法、指标与屏幕外量不到的部分见 `DebugScene+LongChat.swift` 里 `ChatScrollBench` 的注释。

### 交互预算

预算表只在 `InteractionBench.budgets`，指标的定义在 `InteractionBench` 与 `Probes.swift` 的注释里，跑法在 `perf-mac.sh` 头注释里；和预算比的数至少跑两遍取中位数。

冷启动进 Cue 页（iOS 第一项，`launchMs` 是进程启动到对话排出来）要量真实大小的对话：`CUEPAD_PERF_SEED=<真实库的只读副本> xc.sh perf ios 5 -CuePadInteractOnly "冷启动·Cue 页"`（副本先用这个构建打开一次，免得每次都量进升级库结构）。Mac 的"Cue 页首访"带 `contentMs`（点下到对话排出来），大库里有一段 Cue 对话。项名带空格，整个参数要加引号。

`-CuePadInteractOnly 项,项`（两端，跟在 `xc.sh perf <mac|ios> 次数` 之后）只量列出的几项，前后对比省下整套流程（列的项之间要自己够得着，如开编辑页配收编辑页）。iOS 的长文打字（输入框里已有一大段时再敲一个字）配 `-CuePadPasteFile <路径>` 换成真的粘贴内容。

## 同步测量

两台设备之间同步的开销与时延只有一个入口：`apple/scripts/sync-bench.py [分钟=10]`（参数见脚本头注释），前后对比跑同一套。它在这台 Mac 上开两个隔离实例连 CloudKit **开发环境**：A 是有在线会话的 Mac（脚本里的假扩展驱动几个会话不停切状态），B 代替手机，每轮给 A 的一个会话"马上说"一句、对 Cue 说一句、立即同步一次（打点见 `DebugScene+SyncBench.swift`）。

- 前提：这台 Mac 按 Provisioning UDID（`system_profiler SPHardwareDataType`，不是 Hardware UUID）登记过，装了「CuePad macOS Development」描述文件：`provision.py device <UDID> <名称> MAC_OS`，再 `provision.py profiles`。构建由脚本调 `CUEPAD_SIGN=development xc.sh build mac`。
- 只碰开发环境：隔离库连 iCloud 要 Debug 构建、`-CuePadCloudKit YES`、签名里写定 Development 三样都在（`DebugScene.syncsIsolatedLibrary`）。两个实例靠 `-CuePadHost` 当两台 Mac。
- 模拟器没有 Apple 账号、登不了 iCloud，所以 B 是 Mac 进程，当作开着 Agent 页的手机：拉取节奏换成手机那档（`DebugHooks.pollsLikePhone`），界面与通知仍是 Mac 的。
- Cue 不值班（隔离目录里没有登录的运行时）：只量对 Cue 说的话到 A 的库，不量回复。
- 口径：预热（默认 90 秒，含冷启动翻整个同步区）之后的固定窗口。CloudKit 操作按进程统计，来源是 debug 日志里每个操作结束时的 `CKOperationMetrics`：次数按类型与操作组分，字节是 CloudKit 自己计的请求与响应体，不含 TLS 与 HTTP 头。nettop 量不了：CloudKit 的流量都记在 cloudd 名下，和正式版的混在一起。时延用同一台机器的时钟。
- 两个实例共用这台 Mac 的 cloudd，CloudKit 操作在里面排同一个队：一个操作慢（服务端或网络，偶尔几十秒），两边排在后面的一起等，结束在同一刻（报告里的"排队"）。真机上手机有自己的 cloudd，所以尾部时延比真实的大；前后对比在同一网络、同一时段交替跑，主要看中位数。开发环境的同步区随每次运行积累会话记录，只影响冷启动。

## Cue 评测

改 Cue 的提示词（系统提示、工具说明、信封）前后各跑一遍，比同一套场景里真模型的做法：

```bash
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_TOKEN=<令牌> TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/after CUEPAD_TEST_TIME_LIMIT=900 \
  apple/scripts/xc.sh test mac -parallel-testing-enabled YES -only-testing:CuePadTests/CueEvalTests
```

- 大脑是真的 Claude Code，用 Claude 订阅：令牌由跑的人用 `claude setup-token` 生成后经 `TEST_RUNNER_CUEPAD_CUE_EVAL_TOKEN` 给，评测不读 `~/.pi`、`~/.claude`；默认 opus · medium；`TEST_RUNNER_CUEPAD_CUE_EVAL_MODEL`、`TEST_RUNNER_CUEPAD_CUE_EVAL_EFFORT` 换。xcodebuild 只把 `TEST_RUNNER_` 开头的变量交给测试进程。
- 输出目录里每个场景一个 .md（信封、工具调用与结果、Cue 写的消息、判定），`summary.md` 汇总，`system-prompt.md` 是这次的系统提示。有场景没过时命令非零退出，输出照样写完。
- 场景与判定在 `CueEvalTests` 里；模型每次答得不完全一样，结论看两遍以上。

## 崩溃诊断

`Diagnostics` 把 MetricKit 交来的诊断存在资料库目录下（隔离库不订阅）。真机崩溃拿不到栈时，请用户从设置的"上次崩溃"里"导出诊断"发来（摘要未符号化，靠 dSYM 还原：每次发布的归档按构建号存在 `~/Library/Developer/Xcode/Archives/<日期>/CuePad <ios|mac> <构建号>.xcarchive`）。验收：`-CuePadSampleCrash YES` 存一份样例（配 `-CuePadCrashSheet YES` 直接打开摘要）。

先在模拟器里复现：`xc.sh shot`/`rec` 报"截图前 App 退出了"就是崩了，报告带源码行，在 `~/Library/Logs/DiagnosticReports/CuePad-*.ips`。只在会话跑着时崩的，用 `-CuePadStream YES` 让它一轮一轮跑起来（见 `DebugScene+LongChat.swift`）；真实数据用只读副本，改会话状态复现当时的样子。
