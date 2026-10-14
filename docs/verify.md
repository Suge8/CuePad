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
- 模拟器（选哪台、启停、隔离库）只经 `xc.sh`，规则见它的头注释。
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
- 任务行右键（`click` 带 `"button":"right"`）在后台弹得出菜单；墙上的灵感卡右键被当成点按（打开编辑页），它的操作从编辑页走。
- iOS 没有 Simulator.app 窗口可给 bcu 操作：点按用 `axe tap -x <x> -y <y> --udid <模拟器>`（坐标是点，`xcrun simctl io <模拟器> screenshot` 截图换算；`axe describe-ui` 读不到 SwiftUI 的元素），起画面用 `xcrun simctl launch` 带同一组启动参数。模拟器用 `xc.sh` 给这个产物目录建的那台（名为 "CuePad <机型> @ <产物目录>"，见 `_sim.sh`），不碰别人的。

## 性能测量

测量只有一个入口：单次交互（`-CuePadBench interact`）。Mac 是 `apple/scripts/perf-mac.sh`，iOS 是 `apple/scripts/perf-ios.sh`（口径与限制见各自头注释），场景与指标在 `App/Sources/UI/Debug/InteractionBench.swift`。方法与坑：

- 前后对比以进程执行的指令数（`instructionsM`）为准：机器忙时帧间隔和 CPU 时间都会被别的进程拖歪。旧新两个构建交替各跑三遍取中位数。
- 掉帧与动画类指标在前台量：AppKit 的动画只在前台跑，前台每次几何变化还要重算鼠标跟踪区，后台量的数字偏乐观。窗口还得在屏幕上：屏幕外（`-CuePadOffscreen`）display link 不走，只用于布局与日志类场景。
- 掉帧数看的是主线程上 display link 的回调间隔，反映主线程跟不跟得上，不是画面实际交出的帧率；是否真的掉帧以 Instruments 的 Animation Hitches 为准。iOS 模拟器不支持 Animation Hitches，iOS 端用模拟器录屏逐帧或应用内每帧探针。
- Instruments 用 Release 优化构建并保留测量代码（`xcodebuild -configuration Release … 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'`）。
- `xctrace record --template 'Time Profiler' --attach <pid>`；`--launch` 按 bundle id 找进程，机器上有别的 CuePad 时报 ambiguous。
- SwiftUI 模板用 `--attach` 没有数据，要 `--launch` 一份换了 bundle id 的 App 副本（复制后改 `CFBundleIdentifier` 并重签名）；视图更新表与 hitch 表（`hitches`、`hitches-updates`、`hitches-renders`、`hitches-gpu`）都在里面。
- `Animation Hitches` 模板单独录会写出几十 GB，不用；`--launch` 的进程结束后可能停在暂停状态，按它的 PID 结束。
- 会话页滚动（Mac，可不碰指针、不抢焦点）：`-CuePadBench chatscroll`，跑法、指标与屏幕外量不到的部分见 `DebugScene+LongChat.swift` 里 `ChatScrollBench` 的注释。

### 交互预算

预算表只在 `InteractionBench.budgets`，指标的定义在 `InteractionBench` 与 `Probes.swift` 的注释里，跑法在 `perf-mac.sh` 头注释里；和预算比的数至少跑两遍取中位数。

Mac 的 `-CuePadInteractOnly 项,项` 只量列出的几项，前后对比省下整套流程（列的项之间要自己够得着，如开编辑页配收编辑页）。

## 崩溃诊断

`Diagnostics` 把 MetricKit 交来的诊断存在资料库目录下（隔离库不订阅）。真机崩溃拿不到栈时，请用户从设置的"上次崩溃"里"导出诊断"发来（摘要未符号化，靠 dSYM 还原）。验收：`-CuePadSampleCrash YES` 存一份样例（配 `-CuePadCrashSheet YES` 直接打开摘要）。
