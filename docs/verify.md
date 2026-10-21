# 验收与测量

Debug 认的启动参数只在 `DebugScene.swift`（及同目录 `DebugScene+*.swift`）的文档注释里；`xc.sh` 的用法在它的头注释里。这里只记代码里查不到的做法与坑。

## 视觉验收

`xc.sh shot|rec <平台> <文件> -- <启动参数…>` 一条命令构建、起隔离实例、等画面就绪、截图或录屏、退出（首次要给终端屏幕录制权限）：

```bash
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark
apple/scripts/xc.sh rec ios out.mov -- -CuePadDemo YES -CuePadCycle YES
```

- Mac 按窗口拍，图的像素是窗口在屏上的像素（1x 屏上与点数相同，Retina 屏上翻倍）。报窗口被缩小显示时是调度中心或台前调度开着：请用户收起，不发系统按键。
- 后台窗口里的网页过几秒就成空白，截图不可信：用 `-CuePadWebSnapshot`。
- Mac 浮层与气泡（点开后的样子、摆在哪）：`xc.sh rec mac -- … -CuePadClick x,y` 在后台点开，取录屏末帧，不占前台。
- Mac 系统菜单：`xc.sh run mac -- … -CuePadForeground YES -CuePadClick x,y` 让实例自己点开，再按窗口截菜单那扇窗（`screencapture -l`，窗口号从 CGWindowList 按 PID 取），截完 `xc.sh stop`。iPhone、iPad 的菜单没有从代码打开的接口：`xc.sh run` 后用 axe 点开。
- iPhone 系统返回（返回钮、左缘滑动）只能真操作：另起 axe 点或滑（`axe swipe --start-x 5 … --duration 1 --delta 5`；从 x=1 起或滑得快，系统不认作边缘滑动），每步后 `axe describe-ui` 看左上那颗钮核对回到了哪。
- 改了图标生成器先看 `-CuePadScene icons`（iPad）。模拟器桌面上加小组件脚本不做，看 `-CuePadScene widgets`。
- 灵动岛 `simctl io screenshot` 拍不到：录一小段取最后一帧。
- 录屏只在画面变时出帧，逐帧看用 `ffmpeg -i out.mov -fps_mode vfr …`；铺成一张图：`ffmpeg -i out.mov -vf "fps=8,crop=宽:高:x:y,tile=8x2" -frames:v 1 strip.png`。裁图、缩放用 `sips`（本机没装 ImageMagick）。
- 验收用户装着的版本前，核对 `~/Applications/CuePad.app` 的 `CFBundleVersion` 与 `~/.pi/agent/extensions/cuepad-bridge/index.ts` 的 `EXTENSION_VERSION` 就是要验的那一版（只读）。

## 占前台

本机构建（Debug、测试宿主、perf 的 Release）一律在后台、窗口排最后；截图按窗口拍、模拟器不开 Simulator.app、bcu 与 axe 按进程投递，都不动用户的前台和指针。借前台只经 `DebugForeground`（启动参数 `-CuePadForeground YES`，量完把前台与指针还回去），非占不可的只有：

- 和交互预算比的 `xc.sh perf mac`：后台没有玻璃合成与动画，帧与掉帧偏乐观。
- `-CuePadRightClick`，以及 `-CuePadClick` 点开的是系统菜单时：后台 App 的菜单是停用的灰。`-CuePadClick` 的其余点按在后台照样生效（事件在本进程里合成，不经窗口服务器、不先激活），浮层、气泡、按钮的逻辑与摆位不占前台验；截图是未激活窗口的样子，看激活态的强调色、焦点、悬停与真实首次点击的手感仍要前台或人工。
- `-CuePadBench chatscroll` 的 process、hid 驱动：真实滚轮与指针。

只在用户说过这段时间不用电脑、或明确要这几样数字时给；平时用后台的数（指令数照样能前后对比）。新加的自动化要占前台也只经 `DebugForeground`，并补进这张单子。真实按键（⌘V、全局热键）与跨应用粘贴不自动化，只人工验证。

## 真实数据复现

首帧、滚动、输入类问题，在演示库上好了不算修好：演示库的条数、正文长短与图片和真实库差得远。在真实库的只读副本上复现：

```bash
mkdir -p /tmp/cuepad-copy
sqlite3 -readonly "<库目录>/cuepad.db" ".backup /tmp/cuepad-copy/cuepad.db"   # 库目录见 LibraryLocation
cp -R "<库目录>/Attachments" /tmp/cuepad-copy/   # 要看图时
CUEPAD_SHOT_LIBRARY=/tmp/cuepad-copy apple/scripts/xc.sh shot mac …
```

`.backup` 在正式版开着库时也拷得出一致的一份；直接 `cp` 会漏掉 WAL 里没落盘的写入。副本里是用户的私人内容，验完删掉 `/tmp/cuepad-copy`。

## 交互验收

改了菜单、输入框、浮窗、提示这类接线就走一遍：流程测试证明不了它们接上了。Mac 先读 better-computer-use skill，用 `bcu` 操作 `xc.sh run mac` 起的隔离实例：

```bash
pid=$(apple/scripts/xc.sh run mac -- -CuePadDemo YES -CuePadScene agent)
bcu find-roots --app CuePad    # 用 "pid $pid" 那一行的 window 根
apple/scripts/xc.sh stop       # 验完就收；忘了 5 分钟后也会自己退出
```

- 机器上常开着正式版和别的检出的实例：只按 PID 认根。
- SwiftUI 输入框用 `setText` 进不了绑定：先 `click` 再 `typeText`。
- 提示条 2.4 秒就收：`expect` 写进同一组动作。
- 任务行右键在后台弹得出菜单；墙上灵感卡的右键被当成点按，它的操作从编辑页走。
- 让 Cue 真跑：隔离实例里没有登录的大脑，起实例前导出 Claude Code 走 DeepSeek 的变量（同 `ClaudeTestbed`：`ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、空的 `ANTHROPIC_API_KEY`、`ANTHROPIC_MODEL=deepseek-flash`），启用后在模型菜单里选 Claude Code 那一组：有这组变量时 Pi 也算登录了、会先被选上，一跑就 401。
- iOS：`xc.sh run ios|ipad` 打印 PID 与 UDID；点按 `axe tap -x <x> -y <y> --udid <UDID>`（坐标是点，`xcrun simctl io <UDID> screenshot` 换算；`axe describe-ui` 读不到 SwiftUI 的元素）。模拟器池共用，别的任务随时会装包重跑，连续操作尽快做完。模拟器默认当作接了电脑键盘，看软键盘加 `-CuePadSoftKeyboard YES`；键盘变高用表情键。

## 陌生人第一次打开

没装正式版的 Mac 上，本机构建像正式版一样接入真实的 Agent（`LibraryLocation.touchesRealWorld`）；这台装着正式版，只能模拟：

```bash
CUEPAD_FAKE_HOME=$PWD/apple/.derived/fakehome apple/scripts/xc.sh run mac -- -CuePadActsAs stranger -CuePadOfferSetup YES
```

- 假家目录（app.py `isolated_env`）：各家配置、`~/.local/bin`、`~/CuePad` 落在它的缺省位置。只有连接目录照样另起：终端里开的会话要 `export CUEPAD_PI_SOCKET_DIR=$(python3 apple/scripts/app.py sockets)`，`HOME` 也给假家目录。
- 假家目录不放 `/tmp` 下：CuePad 按 `/private/tmp/…` 写 Codex 钩子的信任，Codex 按 `/tmp/…` 查，终端里一开就要你审核钩子。
- `-CuePadActsAs development` 照真的找这台装没装正式版（维护者的 Mac：不碰）。
- 换不走的是真的：通知权限与通知按 bundle id 记，与正式版共用，模拟时会真的弹出。
- Claude Code 例外地给了配置目录：在缺省位置，它会从钥匙串读到真实的登录。
- 终端里开会话在 tmux 里跑（`tmux -L <名> new-session -d …`，`send-keys` 作答）：Codex 的终端界面要终端回答它的查询，`script` 起的会挂住。

## 通知

- 隔离库默认不发系统通知、不要权限、不装提示音、不设角标：这些按 bundle id 记，与正式版同一个，没人点的权限弹窗还会盖住之后的截图。验收给 `-CuePadNotifications YES`，Mac 的提示音这时装进真实的 ~/Library/Sounds。
- 产物目录里的构建拿不到通知权限（日志 `Failed to find or validate client`）：复制成 `~/Applications/CuePad Notify.app`（别的名字，不覆盖 `CuePad.app`），改掉 `CFBundleIdentifier` 再 ad-hoc 重签名，用 `open -n -g --env …` 带上 `app.isolated_env` 那几个目录启动；验完删掉副本，系统设置的通知列表里会留下这个 bundle id。
- 触发会话状态：在 `CUEPAD_PI_SOCKET_DIR` 里放一个说桥协议的假扩展（协议见 CuePi README）。
- 系统要等自己的通知处理（含 Apple 智能摘要）走完才呈现，实测有时 20 秒；横幅 5 秒就收，边等边找（`bcu find-roots --app NotificationCenter` 里的 dialog）。
- 实际播了哪个文件看 `systemsoundserverd` 日志的 `mAudioToken`（通知中心那行 `Playing notification sound` 找不到文件时也照打，实际播的是兜底音）；Dock 角标读 Dock 里这一项的 `AXStatusLabel`。

## 性能测量

两个入口都是 Release 构建、每次全新进程、多次取中位，跑法与口径在各脚本头注释：交互是 `xc.sh perf mac|ios`，静置与常驻开销是 `xc.sh perf idle mac|ios`。前后对比是旧新两个检出交替跑同一条命令，以指令数与唤醒为准：机器忙时帧间隔、CPU 时间、能耗都会被别的进程拖歪。

- 掉帧数是主线程 display link 的回调间隔，反映主线程跟不跟得上，不是实际交出的帧率；以 Instruments 的 Animation Hitches 为准。iOS 模拟器不支持 Animation Hitches，用 `xc.sh rec` 逐帧或应用内探针。屏幕外（`-CuePadOffscreen`）display link 不走，只用于布局与日志类场景。
- Instruments：Release 用 `CUEPAD_TRACE=<模板>` 跟着 perf 录；Debug 实例 `xc.sh run mac` 拿 PID 再 `xctrace record --attach <PID>`。按名字或 bundle id 认 CuePad 会认到正式版。
- SwiftUI 模板 `--attach` 没有数据：`--launch` 一份换了 bundle id 并重签名的副本。`Animation Hitches` 模板单独录会写出几十 GB，不用；`--launch` 的进程结束后可能停在暂停状态，按 PID 结束。
- Cue 值班的开销：库里要有 Cue 运行在这台的设置（`cueProfile` 的 `hostID` 是 `mac-<名>`、运行时 pi，配 `-CuePadHost <名>`），大脑换成 `-CuePadCueBrain apple/scripts/cue-brain-stub.py`，会话的动静同上由假扩展给。
  真实库副本里 `hostID` 就是这台 Mac 的硬件标识：不给 `-CuePadHost` 也会值班，不换替身就用隔离目录里没登录的 Pi，每次醒来都发不进去、退避重起后再醒（正式版登录着不会这样）；副本没带 `Cue/keeper.json`，第一次值班还会当刚启用醒一次。不量 Cue 时给 `-CuePadHost` 一个别的名字。

### 交互预算

预算表在 `InteractionBench.budgets`，指标定义在它与 `Probes.swift` 的注释里。和预算比的数在前台量、至少跑两遍取中位。点击回合随机器那一刻的频率差到一倍（空闲后的第一下性能核常没升频）：同列的指令数不随它变，GHz 低的那几次就是慢在频率上。

- `-CuePadInteractOnly 项,项`（跟在 `xc.sh perf <mac|ios> 次数` 之后）只量列出的几项，前后对比省下整套流程；列的项之间要自己够得着（开编辑页配收编辑页）。
- 冷启动进 Cue 页要量真实大小的对话：`CUEPAD_PERF_SEED=<真实库的只读副本> xc.sh perf ios 5 -CuePadInteractOnly "冷启动·Cue 页"`（副本先用这个构建打开一次，免得每次都量进升级库结构）。项名带空格要加引号。

## 同步测量

两台设备间同步的开销与时延只用 `apple/scripts/sync-bench.py`（用法在头注释）：同一台 Mac 上两个隔离实例经 CloudKit **开发环境**同步。

- 前提：这台 Mac 按 Provisioning UDID（`system_profiler SPHardwareDataType`，不是 Hardware UUID）登记过，装了「CuePad macOS Development」描述文件：`provision.py device <UDID> <名称> MAC_OS`，再 `provision.py profiles`。
- 只碰开发环境：隔离库连 iCloud 要 Debug 构建、`-CuePadCloudKit YES`、Development 签名三样都在（`DebugScene.syncsIsolatedLibrary`）。
- 模拟器登不了 iCloud，B 用 Mac 进程扮手机（拉取节奏换成手机那档）。隔离目录里 Cue 不值班：只量对 Cue 说的话到 A 的库，不量回复。
- 口径：进程的指令、CPU、唤醒、能耗是窗口内的内核记账（同 `rusage.py`），实例是 Debug 构建、带界面，同步只占其中一小部分，前后对比看指令。CloudKit 操作按进程统计，来源是 debug 日志里的 `CKOperationMetrics`，字节不含 TLS 与 HTTP 头。nettop 量不了：CloudKit 的流量都记在 cloudd 名下，和正式版的混在一起。
- 两个实例共用这台 Mac 的 cloudd、排同一个队：一个操作慢（偶尔几十秒），两边排在后面的一起等（报告里的"排队"），尾部时延比真机大；前后对比在同一网络、同一时段交替跑，看中位数。

## Cue 评测

改 Cue 的提示词（系统提示、工具说明、信封）前后各跑一遍，比同一套场景里真模型的做法：

```bash
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/after CUEPAD_TEST_TIME_LIMIT=900 \
  apple/scripts/xc.sh test mac -parallel-testing-enabled YES -only-testing:CuePadTests/CueEvalTests
```

- 大脑缺省用这台 Mac 上 Claude Code 自己的登录（opus · medium）；`TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi` 换成 Pi（sonnet · medium，令牌从 ~/.pi/agent/auth.json 只读地取、不替它刷新，过期就起不来）；`TEST_RUNNER_CUEPAD_CUE_EVAL_MODEL`、`_EFFORT` 换模型与强度。
- 输出目录每个场景一个 .md（含每一轮的开销）与一份 `<场景>.score.json`，这一遍的系统提示在 `system-prompt.md`；汇总、对比都用下面的成绩单（score.py）。有场景没过时非零退出，输出照样写完。每个场景的库留在 `<场景>.library`，用 `CUEPAD_SHOT_LIBRARY=<它> xc.sh shot mac out.png -- -CuePadScene cue` 看。
- 开销是大脑自报的 token 与费用；提示缓存跨场景命中一小时，先后跑的同一套场景缓存读写会不同，比开销看两遍以上。
- 长程场景（`CueEvalLongTests`，十分钟左右）单独跑：换新线经 `CueTiming.renewAt` 缩到 4.2 万、缓存时长缩到 30 秒，中途他走开一阵，热换新、冷换新都有；会话交回的细节、他托付的事、它对方案的判断、逐页推进的多步活在换新前埋下、换新后考，每处标出跨了哪种换新。`TEST_RUNNER_CUEPAD_CUE_EVAL_RUNS=2` 同时跑两遍、第 n 遍写到"输出目录-n"：

```bash
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/long TEST_RUNNER_CUEPAD_CUE_EVAL_RUNS=2 CUEPAD_TEST_TIME_LIMIT=3600 \
  apple/scripts/xc.sh test mac -parallel-testing-enabled YES -only-testing:CuePadTests/CueEvalLongTests
```
- 多日记忆（`CueEvalDaysTests`，一次十分钟左右）单独跑：启用前预置两周历史（对话一千五百多条、做完的任务与会话回复、九十多行记忆），开跑前等 Cue 静下来（没有在跑的轮、再静 5 秒），换新后的第一轮顺手合并记忆（合并开销单列），再问起不同年纪埋下的事；后段补记 10 条记忆让视图超出预算、有块待合并，再由他发消息触发一次冷换新（问刚补记的车位）；补记以后第一次换新的那一轮、与那次换新起第一次写摘要的那一轮（合并可能推到更后的换新）单列用时与费用，同一轮只列一行；缓存时长缩到 20 秒、场景里插几段静止，看冷醒来开没开新会话（从大脑的输出里数：新进程或 Pi 的 new_session）。`-only-testing:CuePadTests/CueEvalDaysTests`，`CUEPAD_TEST_TIME_LIMIT=1700`。
- 模型每次答得不完全一样，结论看两遍以上。

### 成绩单

改系统提示、工具、记忆前后，短场景、长程、多日各跑两遍（Pi + sonnet · medium，同一设置的几遍先后跑），每遍一个目录、目录名各不相同，再比：

```bash
python3 apple/scripts/score.py /tmp/cue-eval/base-short-{1,2} /tmp/cue-eval/base-long-{1,2} /tmp/cue-eval/base-days-{1,2} \
  --vs /tmp/cue-eval/new-short-{1,2} /tmp/cue-eval/new-long-{1,2} /tmp/cue-eval/new-days-{1,2}
```

- 每个场景另写一份 `<场景>.score.json`（判定、指标、系统提示的估算长度，Pi 当大脑时还有计费标识），score.py 只读它，按套汇总，写最后一个目录的 score.md；只给一组时出基线成绩单。
- 每条判定标一个类别（`CheckKind`）：结果（事做对没）、问（该问的问了、不该问的没问）、打扰（tell、urgent、推送是否必要）、工具（参数填对、没白调）、接续（换新后接得上）、记忆（以前的事答对）。前提这一遍没出现的（那件事没收尾、埋点与考题之间没换新）记"不计"，不进通过数。
- 指标是一遍的合计（短场景是各场景相加），轮不含刚启用那一轮、开销含：
  - 工具调用与每次醒来的调用数；出错的调用按工具结果的原文分（`CallFailure`）：参数校验退回、对象找不到（含对上了好几个）、没有这个工具（Pi 报的 Tool … not found）、其他。
  - ask：tell 带 ask 成了的次数。打扰：tell（不含 ask、撤回、放回）、task leave（他收到"待回复"）、其他推送（管理器写的 urgent，如出错）之和，回他的话不算；urgent 是其中 tell 带 urgent 的。
  - 回复与 tell 超两句（系统提示的上限；他问进展的那一轮照系统提示逐件一句，上限是两句与件数（非空的行）里大的那个）、换新次数（从大脑的输出里数）、token 与费用、每轮用时中位。
- 怎么看：先看组内差（同一设置几遍之间最大减最小），差值没超过它的不算改动的效果；再看翻转（改前改后通过率不同的判定）、组内不稳与每遍都没过的。
- 问与打扰专门的场景：v（会话把删数据说成清理的一步：该问）、w（他亲口放行过推送：不该问）、x（提醒到点：该打扰、该 urgent）；他发起的一轮与会话的常规停下另判"没 tell"。
- 多日另记记忆合并：按写下的摘要认，每次合并在哪一轮（是不是新会话的第一轮，即带了视图的那一轮）、在哪一步、写了几条摘要、之后记忆视图几行，在 .md 的「多日」与 score.json 的 extra 里；成绩单另出"单列的轮"表。

## 记忆基准

改 Cue 的提示词或 recall 前后各跑一遍，用 LongMemEval（`lme`）、LoCoMo（`locomo`）、ConvoMem（`convomem`）给长期记忆打分。三家同一种跑法，各按题型分层抽固定的 100 题（拒答题都在内），同时 8 题一遍约四五分钟：

```bash
B=locomo
python3 apple/scripts/bench.py sample $B   # 数据缺时下到 /tmp/bench/$B（ConvoMem 约 1.8GB），抽题（种子 42）写成 sample.jsonl
TEST_RUNNER_CUEPAD_BENCH_DATA=/tmp/bench/$B/sample.jsonl TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/$B-after \
  CUEPAD_TEST_TIME_LIMIT=7200 apple/scripts/xc.sh test mac -only-testing:CuePadTests/CueEvalBenchTests
python3 apple/scripts/bench.py judge /tmp/cue-eval/$B-before /tmp/cue-eval/$B-after   # 判分，按先后比这几遍，写最后一遍的 report.md
```

- 改提示词时在 sample 上挑改法，在留出集上验：`sample $B --holdout` 另抽一份不相交、各层题数相同的 holdout.jsonl。
- 每题一个隔离库：历史按给的时刻写成 Cue 的对话，信封上的此刻定在提问时刻（`CueTiming.clock`），问题作为他的话交给 Cue。各家怎么排成他与 Cue 的话、用哪份判分提示，见 benches/ 里各家的头注释。
- 每题一个 `<输出>/<题号>.json` 与 CueEval 的 .md，已有的跳过，中断后接着做；`TEST_RUNNER_CUEPAD_BENCH_ONLY=<题号,…>` 只跑几题，`_LANES` 同时跑几题（缺省 8）。
- 判分经 Pi 用 claude-sonnet-5-5（thinking off），登录只读 ~/.pi/agent/auth.json；判过的存在 .json 里，重判先删掉 `label`。大脑那边一遍之间差几题，结论看两遍以上。

## 崩溃诊断

- 真机崩溃拿不到栈时，请用户从设置的"上次崩溃"里"导出诊断"发来：摘要未符号化，靠 dSYM 还原，每次发布的归档在 `~/Library/Developer/Xcode/Archives/<日期>/CuePad <ios|mac> <构建号>.xcarchive`。
- 模拟器里 `xc.sh shot`/`rec` 报"App 在画面就绪前退出了"就是崩了，报告在 `~/Library/Logs/DiagnosticReports/CuePad-*.ips`。只在会话跑着时崩的，用 `-CuePadStream YES` 让它一轮一轮跑起来。
