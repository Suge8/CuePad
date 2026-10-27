# 验收

Debug 认的启动参数只在 `DebugScene.swift`（及同目录 `DebugScene+*.swift`）的文档注释里，`xc.sh` 的用法在它的头注释里；这里只记代码里查不到的做法与坑。性能与同步的测量见 [perf.md](perf.md)，Cue 的提示词评测见 [cue-eval.md](cue-eval.md)。

## 视觉验收

截图、录屏用 `xc.sh shot|rec`（首次要给终端屏幕录制权限）。浅深色、几个场景一次调用拍完：`xc.sh shot ios -- -CuePadScene shelf -theme light , -- -CuePadScene shelf -theme dark`（一次进锁、构建、装包；iOS 的模拟器外观随每张的 `-theme` 切）。源码没变时构建自动跳过。

- Mac 的 shot、rec、run 期间自动让显示器醒着（`caffeinate -d -u`），不用自己 `caffeinate -u`。
- Mac 按窗口拍，图的像素是窗口在屏上的像素（1x 屏上与点数相同，Retina 屏上翻倍）。报窗口被缩小显示时是调度中心或台前调度开着：请用户收起，不发系统按键。
- 后台窗口里的网页过几秒就成空白，截图不可信：用 `-CuePadWebSnapshot`。
- Mac 浮层与气泡（点开后的样子、摆在哪）：`xc.sh rec mac -- … -CuePadClick x,y` 在后台点开，取录屏末帧，不占前台。
- Mac 系统菜单：`xc.sh run mac -- … -CuePadForeground YES -CuePadClick x,y` 让实例自己点开，再按窗口截菜单那扇窗（`screencapture -l`，窗口号从 CGWindowList 按 PID 取），截完 `xc.sh stop`。iPhone、iPad 的菜单没有从代码打开的接口：`xc.sh run` 后用 axe 点开。
- iPhone 系统返回（返回钮、左缘滑动）只能真操作：另起 axe 点或滑（`axe swipe --start-x 5 … --duration 1 --delta 5`；从 x=1 起或滑得快，系统不认作边缘滑动），每步后 `axe describe-ui` 看左上那颗钮核对回到了哪。
- 改了图标生成器先看 `-CuePadScene icons`（iPad）。模拟器桌面上加小组件脚本不做，看 `-CuePadScene widgets`。
- 改了状态图形或 Cue 头像的各拍，看 `-CuePadScene stateicons`（会话状态、经过那一行、头像各拍四档，一屏放不下加 `-CuePadSheetEnd YES` 截底半）。换拍的软糖与小动作录 `-CuePadCueCycle YES`（走一圈 `CueNowSamples.tour`，`-CuePadCueCycleSeconds <秒>` 改每拍停多久，默认 2.6；停着的拍子每 15～20 秒才动一下，看小动作录 `-CuePadCueNow quiet` 一分钟）。
- 灵动岛用 `axe screenshot` 拍，展开态按住时拍。
- 录屏只在画面变时出帧，逐帧看用 `ffmpeg -i out.mov -fps_mode vfr …`；铺成一张图：`ffmpeg -i out.mov -vf "fps=8,crop=宽:高:x:y,tile=8x2" -frames:v 1 strip.png`。裁图、缩放用 `sips`（本机没装 ImageMagick）。
- 验收用户装着的版本前，核对 `~/Applications/CuePad.app` 的 `CFBundleVersion` 与 `~/.pi/agent/extensions/cuepad-bridge/index.ts` 的 `EXTENSION_VERSION` 就是要验的那一版（只读）。

## 占前台

本机构建（Debug、测试宿主、perf 的 Release）一律在后台、窗口排最后；截图按窗口拍、模拟器不开 Simulator.app、bcu 与 axe 按进程投递，都不动用户的前台和指针。借前台只经 `DebugForeground`（启动参数 `-CuePadForeground YES`，量完把前台与指针还回去），非占不可的只有：

- 和交互预算比的 `xc.sh perf mac`：后台没有玻璃合成与动画，帧与掉帧偏乐观。
- `-CuePadRightClick`，以及 `-CuePadClick` 点开的是系统菜单时：后台 App 的菜单是停用的灰。`-CuePadClick` 的其余点按在后台照样生效（事件在本进程里合成，不经窗口服务器、不先激活），浮层、气泡、按钮的逻辑与摆位不占前台验；截图是未激活窗口的样子，看激活态的强调色、焦点、悬停与真实首次点击的手感仍要前台或人工。
- `-CuePadBench chatscroll` 的 process、hid 驱动：真实滚轮与指针。
- `-CuePadClick` 的 `front`、`hidpinch`、`hidscroll`（`DebugGestures+Mac.swift`）：在 HID 层合成触控板捏合与带惯性的双指滚动，进得了系统滚动视图（进程内合成的进不去），量全屏页大图的缩放与看图。

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
pid=$(apple/scripts/xc.sh run mac -- -CuePadDemo YES -CuePadScene sessions)
bcu find-roots --app CuePad    # 用 "pid $pid" 那一行的 window 根
apple/scripts/xc.sh stop       # 验完就收；忘了 5 分钟后会自己退出
```

- 机器上常开着正式版和别的检出的实例：只按 PID 认根。
- SwiftUI 输入框用 `setText` 进不了绑定：先 `click` 再 `typeText`。
- 提示条 2.4 秒就收：`expect` 写进同一组动作。
- 任务行右键在后台弹得出菜单；墙上灵感卡的右键被当成点按，它的操作从编辑页走。
- 让 Cue 真跑：隔离实例里各家的配置目录是空的、没有登录的大脑。起实例前同 `ClaudeTestbed` 把这台 Claude Code 的登录交给它：`export CLAUDE_CODE_OAUTH_TOKEN="$(<ClaudeLogin.tokenCommand 那条命令>)" ANTHROPIC_API_KEY=`（只读钥匙串里的访问令牌，不刷新），启用时选 Claude Code。
- iOS：`xc.sh run ios|ipad` 打印 PID 与 UDID；点按 `axe tap -x <x> -y <y> --udid <UDID>`（坐标是点，`xcrun simctl io <UDID> screenshot` 换算；`axe describe-ui` 读不到 SwiftUI 的元素）。`run` 起的实例由后台看守租着那台模拟器（别的检出领不到），到 `CUEPAD_RUN_SECONDS`、实例退出或 `xc.sh stop` 才放；`shot`、`rec` 只在拍的那几秒占着。模拟器默认当作接了电脑键盘，看软键盘加 `-CuePadSoftKeyboard YES`；键盘变高用表情键。

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

## 崩溃诊断

- 真机崩溃拿不到栈时，请用户从设置的"上次崩溃"里"导出诊断"发来：摘要未符号化，靠 dSYM 还原，每次发布的归档在 `~/Library/Developer/Xcode/Archives/<日期>/CuePad <ios|mac> <构建号>.xcarchive`。
- 模拟器里 `xc.sh shot`/`rec` 报"App 在画面就绪前退出了"就是崩了，报告在 `~/Library/Logs/DiagnosticReports/CuePad-*.ips`。只在会话跑着时崩的，用 `-CuePadStream YES` 让它一轮一轮跑起来。
