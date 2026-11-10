# 验收

Debug 认的启动参数只在 `DebugScene+Args*.swift` 的字段注释里（拼错的参数启动即报错退出），画面登记在 `DebugScene+Scenes.swift` 的 `DebugScene.entries`、各画面在 `UI/Debug/Scenes/`，`xc.sh` 的用法在它的头注释里；这里只记代码里查不到的做法与坑。性能与同步的测量见 [perf.md](perf.md)，Cue 的提示词评测见 [cue-eval.md](cue-eval.md)，崩溃与真机日志见 [diagnose.md](diagnose.md)。

## 视觉验收

截图、录屏用 `xc.sh shot|rec`（首次要给终端屏幕录制权限）。几个场景一次调用拍完：`xc.sh shot ios -- -CuePadScene shelf , -- -CuePadScene cue -theme dark`（一次进锁、构建、装包；外观用 `-theme`，iOS 的模拟器外观随每张切）。源码没变时构建自动跳过。

- iPhone、iPad 横屏加 `-CuePadLandscape YES`：`xc.sh` 起实例前把模拟器的物理朝向横过来（`devicectl device orientation`，不发键鼠事件）。App 自己转不了 iPad：支持多任务的 App，系统按设备朝向定界面方向，不理 `requestGeometryUpdate`。iPad Pro 11 横屏宽 1210，会话条与 Cue 同开放不下，会话条开着的样子要 Cue 收起（`WideMetrics`）。
- Mac 按窗口拍，图的像素是窗口在屏上的像素（1x 屏上与点数相同，Retina 屏上翻倍）。报窗口被缩小显示时是调度中心或台前调度开着：请用户收起，不发系统按键。
- 后台窗口里的网页过几秒就成空白，截图不可信：用 `-CuePadWebSnapshot`。
- `xc.sh shot` 截的是点击之前的画面：要看点击后的结果，用 `rec` 录屏取最后一帧。
- Mac 浮层与气泡（点开后的样子、摆在哪）：`xc.sh rec mac -- … -CuePadClick x,y` 在后台点开，取录屏末帧，不占前台。
- Mac 菜单快捷键（如全屏页里 PDF 的 ⌘F 查找条）：`-CuePadClick "wait:1;cmd:f;type:词"`，`cmd:键` 从窗口焦点沿响应链发主菜单那一项的动作（后台窗口收不到菜单快捷键），同样取录屏末帧。
- Mac 系统菜单：`xc.sh run mac -- … -CuePadForeground YES -CuePadClick x,y` 让实例自己点开，再按窗口截菜单那扇窗（`screencapture -l`，窗口号从 CGWindowList 按 PID 取），截完 `xc.sh stop`。iPhone、iPad 的菜单没有从代码打开的接口：`xc.sh run` 后用 axe 点开。
- iPhone 系统返回（返回钮、左缘滑动）只能真操作：另起 axe 点或滑（`axe swipe --start-x 5 … --duration 1 --delta 5`；从 x=1 起或滑得快，系统不认作边缘滑动），每步后 `axe describe-ui` 看左上那颗钮核对回到了哪。
- 改了图标生成器先看 `-CuePadScene icons`（iPad）。模拟器桌面上加小组件脚本不做，看 `-CuePadScene widgets`。
- 改了状态图形或 Cue 头像的各拍，看 `-CuePadScene stateicons`（会话状态、经过那一行、头像各拍四档，一屏放不下加 `-CuePadSheetEnd YES` 截底半）。换拍的软糖与小动作录 `-CuePadCueCycle YES`（走一圈 `CueNowSamples.tour`，`-CuePadCueCycleSeconds <秒>` 改每拍停多久，默认 2.6；停着的拍子每 15～20 秒才动一下，看小动作录 `-CuePadCueNow quiet` 一分钟）。
- 灵动岛用 `xc.sh run ios -- -CuePadScene cue -CuePadCueNow busy -CuePadLiveActivity YES` 租到自己的模拟器，axe 按该 UDID 回桌面、截图、长按与锁屏；展开态按住时拍。`activity` 画面只预览共享视图，不证明系统宽度、状态栏或高度限制。分别在 iPhone 17 与 18 Pro/Pro Max 核对时间和电量；大数、未知数样例在 `CueActivitySamples`。双活动要用另一个调试身份的隔离合成活动：同一 App 的多个活动仍会合成一个紧凑展示，不能证明最小态或系统窄位。
- 系统岛的轮播验收加 `-CuePadCueCycle YES -CuePadCueCycleSeconds 6`，由本地演示更新系统活动；录屏仍经 `xc.sh rec`。这是状态变化的过渡，不是常驻循环。模拟器回桌面或打开通知中心后也可能挂起演示 App，轮播会停；只以实际变更的帧为证，不用录制请求时长推算帧率。App 的 `-CuePadReduceMotion` 与语言参数不传进 Widget 进程：系统岛需在租到的模拟器设置对应语言、减少动态效果后验收，结束还原。
- 页面打开后第一次切换（第一次进入发送、工作、同步这类）要从启动前录（`CUEPAD_REC_LAUNCH=1`）：就绪后才开录的话，打开时的样子已经过去了，录不到那一下。
- 录屏只在画面变时出帧，逐帧看用 `ffmpeg -i out.mov -fps_mode vfr …`；铺成一张图：`ffmpeg -i out.mov -vf "fps=8,crop=宽:高:x:y,tile=8x2" -frames:v 1 strip.png`。裁图、缩放用 `sips`（本机没装 ImageMagick）。
- 验收用户装着的版本前，核对 `~/Applications/CuePad.app` 的 `CFBundleVersion` 与 `~/.pi/agent/extensions/cuepad-bridge/index.ts` 的 `EXTENSION_VERSION` 就是要验的那一版（只读）。

## 占前台

本机构建（Debug、测试宿主、perf 的 Release）一律在后台、窗口排最后；截图按窗口拍、模拟器不开 Simulator.app、bcu 与 axe 按进程投递，都不动用户的前台和指针。借前台只经 `DebugForeground`（启动参数 `-CuePadForeground YES`，量完把前台与指针还回去）。**用户键鼠静止不足 60 秒时代码直接拒借**：实例打印读数、退出码 2，`xc.sh` 的命令随之失败，不会降级成后台，重试也一样；用户确实在场时改用后台量。非占不可的只有：

- 和交互预算比的 `xc.sh perf mac`：后台没有玻璃合成与动画，帧与掉帧偏乐观。
- `-CuePadRightClick`，以及 `-CuePadClick` 点开的是系统菜单时：后台 App 的菜单是停用的灰。`-CuePadClick` 的其余点按在后台照样生效（事件在本进程里合成，不经窗口服务器、不先激活），浮层、气泡、按钮的逻辑与摆位不占前台验；截图是未激活窗口的样子，看激活态的强调色、焦点、悬停与真实首次点击的手感仍要前台或人工。
- `-CuePadBench chatscroll` 的 process、hid 驱动：真实滚轮与指针。
- `-CuePadClick` 的 `front`、`hidpinch`、`hidscroll`、`hiddrag`（`DebugGestures+Mac.swift`）：在 HID 层合成触控板捏合、带惯性的双指滚动与按住拖，进得了系统滚动视图（进程内合成的进不去），量全屏页大图的缩放与看图；拖窗口边录宽屏跨阈值。

前台量会抢键盘、移指针：只在要和预算比的那几样数字上用，一次量够，不连跑；前后对比只要指令数就用后台。新加的自动化要占前台也只经 `DebugForeground`，并补进这张单子。真实按键（⌘V、全局热键）与跨应用粘贴不自动化，只人工验证。

## 真实数据复现

首帧、滚动、输入类问题，在演示库上好了不算修好：演示库的条数、正文长短与图片和真实库差得远。在真实库的只读副本上复现：

```bash
mkdir -p /tmp/cuepad-copy
sqlite3 -readonly "<库目录>/cuepad.db" ".backup /tmp/cuepad-copy/cuepad.db"   # 库目录见 LibraryLocation
mkdir -p /tmp/cuepad-copy/Caches && cp -cR ~/Library/Caches/CuePadAttachments /tmp/cuepad-copy/Caches/   # 要看附件时：本机那份
cp -cR "<库目录>/Attachments" /tmp/cuepad-copy/   # 还没上传的保底（结构 77 之前的库，附件全在这里）
CUEPAD_SHOT_LIBRARY=/tmp/cuepad-copy apple/scripts/xc.sh shot mac …
```

`.backup` 在正式版开着库时也拷得出一致的一份；直接 `cp` 会漏掉 WAL 里没落盘的写入。副本里是用户的私人内容，验完删掉 `/tmp/cuepad-copy`。

## 交互验收

改了菜单、输入框、浮窗、提示这类接线就走一遍：流程测试证明不了它们接上了。Mac 先读 better-computer-use skill，用 `bcu` 操作 `xc.sh run mac` 起的隔离实例：

```bash
pid=$(apple/scripts/xc.sh run mac -- -CuePadDemo YES -CuePadScene sessions)
bcu find-roots --app CuePad    # 用 "pid $pid" 那一行的 window 根
apple/scripts/xc.sh stop       # 验完就收；忘了 5 分钟后会自己退出
```

- 机器上常开着正式版和别的检出的实例：只按 PID 认根。
- SwiftUI 输入框用 `setText` 进不了绑定：先 `click` 再 `typeText`。
- 提示条 4 秒就收（带撤销、归档或出错的 8 秒），指针停在上面时不收：`expect` 写进同一组动作。后台录屏计时：`xc.sh rec mac -- … -CuePadNotice 字 -CuePadHover <提示条上一点> -CuePadHoverSeconds <秒>`（停那么久后移开，应在移开后再满 8 秒才收），读屏开着不收用 `-CuePadReader YES`（同一条路）；真实指针、键盘焦点与真机旁白仍要人工。
- 任务行右键在后台弹得出菜单；墙上灵感卡的右键被当成点按，它的操作从编辑页走。
- 让 Cue 真跑：隔离实例里各家的配置目录是空的、没有登录的大脑。起实例前同 App 的 Cue 评测（`EvalBrain`）把这台 Claude Code 的登录交给它：`export CLAUDE_CODE_OAUTH_TOKEN="$(<ClaudeLogin.tokenCommand 那条命令>)" ANTHROPIC_API_KEY=`（只读钥匙串里的访问令牌，不刷新），启用时选 Claude Code。
- 通话（接通、后台、中断、信令断开、交接与朗读）的验收步骤在 [verify-voice.md](verify-voice.md)。
- iOS：`xc.sh run ios|ipad` 打印 PID 与 UDID；读、点、输入用 `apple/scripts/ui.py <UDID|iphone|ipad> read|tap|paste|key|wait|shot`（AXe 的薄封装，用法在它的头注释），不直接调 `axe tap --label`。
  `run` 起的实例由后台看守租着那台模拟器（别的检出领不到），到 `CUEPAD_RUN_SECONDS`、实例退出或 `xc.sh stop` 才放；`shot`、`rec` 只在拍的那几秒占着。槽位全机共用（`_lock.sh`），换机型的任务会关掉同槽位上别的机型。
  模拟器默认当作接了电脑键盘，看软键盘加 `-CuePadSoftKeyboard YES`；键盘变高用表情键。模拟器里的系统开关（设置里的开关、权限弹窗）普通点按点不动，要 `ui.py … tap … --physical`。
- AXe 的树（iOS 27.0 模拟器、AXe 1.8.0 实测）读得出 SwiftUI 的按钮、输入框、文字，带标签、值与框（Cue 页约 100、看板约 150 个有标签的，读一次 1～3 秒，截图 0.2 秒），三个主画面在 iPhone 与 iPad 上都读得出。四处要知道：
  树里连着屏外的页与零尺寸的重名分身，`axe tap --label` 遇重名直接拒绝（iPad 上六次全拒），`ui.py tap` 只数屏上的、按框的中心点；
  系统菜单与弹出层（项目页"更多"菜单）不在树里，用快捷键（`ui.py … key cmd+n` 记一条灵感）或按截图的坐标点；
  中文用 `ui.py … paste`（剪贴板加 ⌘V，不弹粘贴许可，输入框的值读得回来），`axe type` 只认美式键盘；
  多数元素没有 `AXUniqueId`，按标签找。
- Mac 读界面用 bcu：`observe-ui` 把大多数节点折起来，找字用 `bcu search-ui --pid <PID> --text …`（找不到时退出码也是 0，看输出里 "N of M matches"）。

## 多设备同时验收

`xc.sh fleet up|accept|down` 在本检出同时起 Mac、iPhone、iPad 三个隔离实例，共用一朵模拟云；用法、隔离与真云（`cloud-sims`、`up --real`）在 `fleet.py` 头注释，各端用 `ui.py iphone|ipad|mac …` 操作（Mac 只有读与等）。脚本里没写的：

- `accept` 打印的时刻是各端读完界面那一刻，分辨率是一轮读界面的时长（iPad 约 1～3 秒，Mac 不到 1 秒），不是同步时延；时延用 `sync-bench.py`（[perf.md](perf.md)）。
- 真云的两台专用模拟器要在各自的设置里登同一个测试 Apple ID（一次性，登录态留在模拟器里）；不登时 App 照常起、不同步，`accept` 读不到。
- 真云有 CloudKit 限流（[perf.md](perf.md)「真 CloudKit」），模拟器是否与这台 Mac 的正式版共用那份没测过，少跑。
- 验不了：推送、真网络、两个账号间的隔离；只能真机、真账号验收。

## 读屏验收

iOS 旁白走到哪以旁白真走为准，不用 axe 的树（它连 `accessibilityHidden` 的也列出）。`xc.sh run ios -- … -CuePadAXFocus YES` 起实例，在租到的模拟器里开旁白：`xcrun simctl spawn <UDID> defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool true`，再 `launchctl kickstart user/foreground/com.apple.VoiceOverTouch`（第一次弹的"旁白手势"说明双击"好"收掉）。单指快扫（`axe swipe`，0.12 秒、180 点）走一格，点一下落焦点；双击要两次点按隔 0.15 秒，同一个 `axe batch` 里太慢，起两个 `axe touch`。每一格写进库目录的 `ax-focus.txt`。验完关掉（`VoiceOverTouchEnabled -bool false`、`launchctl kill SIGTERM user/foreground/com.apple.VoiceOverTouch`）再 `xc.sh stop`：槽位全机共用，下一个任务会接着开着旁白。

## 陌生人第一次打开

没装正式版的 Mac 上，本机构建像正式版一样接入真实的 Agent（`LibraryLocation.touchesRealWorld`）；这台装着正式版，只能模拟：

```bash
CUEPAD_FAKE_HOME=$PWD/apple/.derived/fakehome apple/scripts/xc.sh run mac -- -CuePadActsAs stranger -CuePadOfferSetup YES
```

- 假家目录（`app_env.py` 的 `isolated_env`）：各家配置、`~/.local/bin`、`~/CuePad` 落在它的缺省位置。只有连接目录照样另起：终端里开的会话要 `export CUEPAD_PI_SOCKET_DIR=$(python3 apple/scripts/app.py sockets)`，`HOME` 也给假家目录。
- 假家目录不放 `/tmp` 下：CuePad 按 `/private/tmp/…` 写 Codex 钩子的信任，Codex 按 `/tmp/…` 查，终端里一开就要你审核钩子。
- `-CuePadActsAs development` 照真的找这台装没装正式版（维护者的 Mac：不碰）。
- 换不走的是真的：通知权限与通知按 bundle id 记，与正式版共用，模拟时会真的弹出。
- Claude Code 例外地给了配置目录：在缺省位置，它会从钥匙串读到真实的登录。
- 终端里开会话在 tmux 里跑（`tmux -L <名> new-session -d …`，`send-keys` 作答）：Codex 的终端界面要终端回答它的查询，`script` 起的会挂住。

## 通知

- 隔离库默认不发系统通知、不要权限、不装提示音、不设角标：这些按 bundle id 记，与正式版同一个，没人点的权限弹窗还会盖住之后的截图。验收给 `-CuePadNotifications YES`，Mac 的提示音这时装进真实的 ~/Library/Sounds。
- 产物目录里的构建拿不到通知权限（日志 `Failed to find or validate client`）：复制成 `~/Applications/CuePad Notify.app`（别的名字，不覆盖 `CuePad.app`），改掉 `CFBundleIdentifier` 再 ad-hoc 重签名，用 `open -n -g --env …` 带上 `app_env.py` 的 `isolated_env` 那几个目录启动；验完删掉副本，系统设置的通知列表里会留下这个 bundle id。
- 触发会话状态：在 `CUEPAD_PI_SOCKET_DIR` 里放一个说桥协议的假扩展（协议见 CuePi README）。
- 系统要等自己的通知处理（含 Apple 智能摘要）走完才呈现，实测有时 20 秒；横幅 5 秒就收，边等边找（`bcu find-roots --app NotificationCenter` 里的 dialog）。
- 实际播了哪个文件看 `systemsoundserverd` 日志的 `mAudioToken`（通知中心那行 `Playing notification sound` 找不到文件时也照打，实际播的是兜底音）；Dock 角标读 Dock 里这一项的 `AXStatusLabel`。
