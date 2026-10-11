# CuePad 开发文档

CuePad 是 Swift 原生应用：macOS 26+、iOS/iPadOS 27+，iCloud 同步，Pi 深度集成。Swift 6 严格并发，界面 SwiftUI，编辑器与菜单栏面板用 AppKit/UIKit。产品说明见 [README.md](../README.md)，模块与术语见 [AGENTS.md](../AGENTS.md)。

本文只记代码、注释和 `--help` 看不出的东西：约定、选择的理由、配置没承认的坑、验收与发布流程。界面行为的规格在各视图文件的头注释和测试里，这里不复述。每次改动先读完本文；下表里的文件只在碰到那件事时读。

| 情形 | 读 |
| --- | --- |
| 改同步、投送请求、CloudKit 记录或订阅、拉取节奏，或排查同步 | [sync.md](sync.md) |
| 改界面的配色、动效、玻璃、布局、渲染性能 | [ui.md](ui.md) |
| 截图验收、布局压力、性能测量、交互预算、崩溃诊断 | [verify.md](verify.md) |
| 签名、发布、证书、Sparkle 更新、图标、部署 CloudKit 结构 | [release.md](release.md) |
| 改 Pi 桥、扩展、socket 协议 | [CuePi README](../apple/CuePadKit/Sources/CuePi/README.md) |

## 环境与命令

需要 Xcode 27。统一入口 `apple/scripts/xc.sh <build|test|shot> <mac|ios|ipad> [截图路径]`，退出码即 xcodebuild 的退出码；ios 与 ipad 是模拟器，默认设备见脚本头注释，`CUEPAD_IOS_DEVICE` / `CUEPAD_IPAD_DEVICE` 覆盖。共用 Swift 包在 `apple/CuePadKit`，直接用 SwiftPM。

```bash
apple/scripts/xc.sh test mac
apple/scripts/xc.sh test ios        # App 测试里 iOS 也编译的部分，再加 CuePadKit 在模拟器上的测试（iOS 编辑器等只在这里跑；带收窄参数时只跑前者；摘要里的 "Executed 0 tests" 只数 XCTest，Swift Testing 不在内）
apple/scripts/xc.sh test mac -only-testing:CuePadTests/<套件>   # test 后的参数原样传给 xcodebuild，用来收窄
cd apple/CuePadKit && swift test
cd apple/CuePadKit && swift build -c release --product cuepad   # 命令行
```

构建产物在 `apple/.derived/`。并行的 agent 各设 `CUEPAD_DERIVED=/tmp/xxx`，截图、隔离库、Pi 目录随之落在该目录下；共用同一目录时构建与测试会互相覆盖而随机失败。

编译报"没有这个成员"但代码里明明有，通常是旧的模块缓存：删掉 `<产物目录>/Build/Products/<平台>/Cue*.swiftmodule` 再编。

## 代码地图

模块表在 AGENTS.md，边界由 `Package.swift` 声明；CueStore 依赖 CueText（图片引用），测试共用的支撑在 `Tests/CueTestSupport`。App 工程的源码目录是文件夹同步组，增删文件不用改工程文件；例外是 `CuePadKit/Tests/CuePiTests/FakeExtension.swift`，Xcode 工程直接引用它（CuePadKit 的桥测试与 App 测试共用）。

## 约定

**资料库位置与隔离。**
- 位置规则唯一来源是 `CueStore` 的 `LibraryLocation`：macOS 在 `~/Library/Application Support/CuePad/Library/`，iOS 在 App Group 容器。App、命令行与测试都经它取位置。
- 环境变量 `CUEPAD_LIBRARY_DIR`（绝对路径）指向隔离目录：资料库、偏好设置（主题、快捷键、上次打开的项目、窗口位置）都放进去，不碰真实的 `com.sugeh.cuepad` 偏好域，并行实例互不影响。
- 资料库打不开（更早或更新版本建的库、损坏）时不终止进程，也不换成空库：入口 `AppServices.openLibrary(at:)` 抛 `LibraryFailure`，两端显示 `UnreadableLibraryView`，没有任何写入入口。位置本身有误（没有 App Group 权限、路径不是绝对路径）时 iOS 走同一页，Mac 提示后退出。

**数据。**
- 灵感与任务是同一张表、同一种同步记录 `Card`（术语见 AGENTS.md）。层级只有 `parentID`，只经 `createTask(_:under:)`、`createCard(body:under:)`、`moveCard` 改，校验在 Store 写入时做；手动顺序用分数索引字符串，避免多设备排序冲突。
- 项目只有一种顺序，在 `CueStore.projects()` 的 SQL 里一处定义，所有项目列表与选择器都用它；Pi 会话的状态变化不计入，否则 Agent 一动，侧栏项目就换位置、⌘1–9 跟着变。
- 给用户看的任务数只有一处定义 `CueStore.taskCounts`（只计显示在顶层的任务），各处不另算；子任务进度与提示词计数只写在上级那一行（`childMarks`）。提示词的"已回复"由发送记录、会话状态与会话的对话推出，不存字段，所以清理对话（`prunePiMessages`，会话安静 7 天后）跳过仍被未归档、未删除的提示词引用的会话，整段对话留着。
- 空白灵感离开编辑就不留下，收尾只有 `CueStore.dropIfBlank` 一处。
- 软删除只留 `deletedAt`；项目删除时其下的灵感与任务随项目进回收站，由项目推导，不逐条记录来源。
- 设备本地偏好进 UserDefaults，不进同步库；变量上次取值存在那条灵感或任务上并同步。
- 同步记录里的枚举字段读出为 `Open<已知枚举>`：其他版本写入、本版本不认识的值是 `.unknown`，原样写回，不当成已知值；本机只写已知值。
- 界面据 Store 的观察流重读，不在内存复制状态。观察以表为粒度；依赖哪些表由读取自己决定（`CueStore.observe` 靠 SQLite 授权回调记下读到的表），订阅只有这一种写法、调用处不写表名；只要"变了就叫我"的也读一个会跟着变的值（计数、列表、记录在不在，如 `hasAttachment`）。读到的值一律可比较（`Equatable`），和上一次一样就不产出——比较只在 Store 一侧做一次，重新订阅时手里已有的值当作上一次（`observe(after:)`），主线程不再比。
- 改表结构：在 `Schema.upgrades` 末尾追加一步并同步改 `create`；升级里任何会因数据冲突失败的语句都会让启动失败，要考虑别的设备已经同步来的数据。当前结构版本与基线见 `Schema`。

**界面里的项目。**
- 每个窗口一份项目目录 `ProjectCatalog`（`Workspace.observeCatalog` 订阅）；名称、图标、计数、目录、⌘1–9 顺序和所有项目选择器都从它同步取，页面与菜单不各自再读。
- 目录读到前根视图不显示页面，所以进入项目页、打开菜单的第一帧就是真实值；顶栏的标题与信息在推入时定下，推入后再改会让整页跳一下，不能等页面数据。
- 项目操作与灵感、任务的操作各只有一份定义（`ProjectActions`、`CardActions`），Mac 右键、iOS 长按与"更多"共用，平台只补各自的发送。
- 绑定文件夹经 `FilePicker`（Mac，非模态，不用 `runModal`）或 `FolderPickerSheet`（手机，经投送请求让 Mac 绑），规则同一份 `ProjectFolders`。

**Mac 页面与首次成本。**
- 内容区把去过的页都挂着（`PageStack`，至多 `MacPages.keptPages` 个），切页只换哪一页看得见；不在前台的页不可见、点不到、暂停订阅（`observing` 读 `pageActive`）。会话页不留。
- 整个窗口一份的数据页面直接读、不各自订阅：`Workspace.agentLinks`、`folderGuide`；整个 App 一份的此刻有事的会话 `AppServices.liveSessions`。只有按搜索词、项目或分页筛的列表各自查。
- 首次使用才付的一次性成本在启动后空闲时先付掉（`Prewarm`）；新增有首次成本的界面要加进去，加之前量出收益。成本是现建整页本身、付一次替身也省不掉的页（Agent 页：十几行会话的成本摊在按钮、右键菜单、走字计时、状态标等几十个视图上，没有单个热点）直接把真的那一页先挂上（`Workspace.premount`），它不在前台也先读一份数据（`pagePrefetch`），第一次点开就是回访。
- 会话页的标题与"⋯"是主窗口常驻的工具栏项，进出会话页不增删工具栏项（"⋯"没有内容时透明、点不到；增删会让整组重建），标题项宽度固定（尺寸一变整条工具栏重排）。会话页第一圈只出标题、状态与最新的对话，回复框、问题卡与"⋯"晚两帧（`NextFrame`）。
- 每帧挪动 AppKit 视图的动画里，页面不接指针（`Workspace.sidebarMoving`）；新增这类动画照此办。

**图片。** 按内容哈希存文件去重，正文存附件引用。文件经 `CueStore.files` 同步写入（编辑器在主线程直接用）；附件记录（同步载体）由引用它的写入在同一事务里登记，没被引用的图片不上传。缩略图只有 CueEditor 的 `Thumbnails` 一套，派生数据，不落盘不同步。

**复制。** `AppServices.copy` 一处，不写发送记录。Mac 上单条目同时放文字与 PNG 时图形应用只取其一，所以含图的正文写成按原顺序含图的 RTFD 并附纯文字兜底（`Clipboard.write`）；iOS 每段文字、每张图片各一个条目。

**预览（Agent 发到手机上看的文件）。**
- Agent 在命令行执行 `cuepad show <文件> [--title 标题]`：不在 Agent 里加别的东西，以后接 Codex、Claude Code 同样是这条命令加同一份 skill。会话由环境变量 `PI_SESSION_ID` 认出，认不出就报错、不猜。
- 预览不是会话文件里的内容：对话仍只来自会话文件，预览卡按创建时间插进对话（`PiChat.entries`）。
- HTML 只读渲染、不联网也读不到别的文件，所以必须是单个文件；`addPreview` 列出页面引用的外部地址，让 Agent 改成单文件再发。否决的方案：在 Mac 上替它内联——样式里的 url()、字体、模块脚本都要处理，漏一类就是静默缺图。
- 网页的内容拦截规则只放行 data:、blob:、about:，规则装不上就不打开（`PreviewWebGuard`，`PreviewWebTests` 用本机端口核对）。

**冲突。** iCloud 按记录同步；同一条灵感或任务离线并发编辑时保留两个版本交给用户选择，不静默覆盖。两台设备离线并发挪动可能合成环、超过三级、挂到灵感下或下级与上级不同项目：应用远端变更后按确定规则收敛（`CardLinks.repairs`，只查这次批量涉及的卡与其子孙），各设备算出同一结果并推送。

**编辑器。** 存储格式是纯字符串，唯一事实源：分割线是独占行 `---split---`（发出去写成 `---`），图片是行内 `![](cuepad://img/<哈希>)`；保存只经序列化，编辑器内复制输出存储格式。不得访问 `NSTextView.layoutManager` / `UITextView.layoutManager`（一次访问就永久降级到 TextKit 1）。

**Pi 桥。** 协议、版本策略（不做版本协商）、多客户端、已知边界与 Pi 集成（扩展与 skill 的安装、升级、同意）都以 CuePi README 为准；App 层只有 `PiIntegrationManager` 管首次同意与静默升级，没有第二套状态。实时状态只在内存，历史只来自 Pi 会话文件。

**命令行。** `cuepad` 随 App 分发在 `CuePad.app/Contents/Helpers/cuepad`，由 `CuePadCLI` 目标构建、随 App 签名与公证。设置里的开关在 `~/.local/bin/cuepad` 建符号链接（位置被别的文件占用时不覆盖；不做需要提权的 `/usr/local/bin`）。它与 App 用同一套资料库位置规则。`cuepad --help` 是其唯一文档。

**用"·"分段的字。** 一行里用"·"隔开几段（"25 条灵感 · 3 项任务"）只经 `Dotted`（`App/AppGroup/Dotted.swift`）拼：屏幕上写"·"，读屏读逗号停顿；各处不手拼 `" · "`，也不单独画 `Text("·")`（要画用 `Dot`）。`DotSeparatorTests` 扫源码拦下直接写的 `" · "`。

**测试。** Swift Testing。
- 测试只用替身或不产生按键事件的系统调用，不向其他应用发送键鼠事件；全局热键的物理触发与跨应用粘贴只能人工验证。
- 服务测试用临时目录、独立 UserDefaults、私有命名剪贴板与内存热键，后台托管 Pi 用记录型替身（`RecordingHost`）。
- 与 Pi 的交互走真 `PiBridge` + 假扩展（`FakeExtension`，socket 上说桥协议；socket 路径有 104 字节上限，所以目录在 /tmp 下），不碰真实资料库、`~/.pi` 和其他应用。
- 真实 Pi 与本机 FireCode 的端到端测试（`Real*Tests`）读 `~/.pi` 里装的 FireCode 源码，`CUEPAD_FIRECODE_SOURCE` 指向另一份检出时改读它。

**macOS 壳层。** 主窗口在 `MainWindowFactory` 创建时就设好外框，界面不要再在运行时改窗口样式。退出时先等服务收尾再放行，整体最多约 2 秒，卡住的组件不拦着退出、记一条 `shutdown` 日志指出是哪个；收尾的等待不在主线程上（`terminate` 可能在主线程任务里被调用，那时主线程上排队的任务轮不到），所以同步引擎等组件的接口不能隶属主线程。单元测试以 App 为宿主，宿主检测到 `XCTestConfigurationFilePath` 时不启动壳层，避免注册真实全局热键和菜单栏图标。

**iOS / iPadOS。**
- 资料库在 App Group 容器 `group.com.sugeh.cuepad` 的 `Library/`；真机需要开发者账号给 App、分享扩展、小组件三个目标签上该 App Group。
- 资料库始终只有主 App 写：分享扩展把内容放进 `Capture/`，主 App 前台收到进程间通知时入库；小组件与扩展只读主 App 写的 JSON 快照。
- 每个窗口各有自己的导航路径，当前项目只从路径推出（`Navigation.currentProject`）；iPad 侧栏选中的项目存进这个窗口的场景存储，不放全局偏好。
- 有同步时每个窗口出现后请求通知权限并注册远程通知；前台不展示系统通知，前台的提示是 App 内横幅，"要不要提示"与 Mac 置位推送标志同一条规则 `PiAlert.entering`。

## 同步

拉取节奏、投送请求、Agent 锁屏通知、排查与真机验证见 [sync.md](sync.md)。

### CloudKit 数据结构

`apple/CloudKit/cuepad.ckdb` 由同步记录映射生成，不手写；映射改了 `CloudKitSchemaTests` 会失败。重新生成、导入开发环境与在控制台部署生产环境的步骤见 [release.md](release.md)。

## 视觉

配色、动效、玻璃、字号与措辞的约定见 [ui.md](ui.md)；具体界面的规格以各视图文件的头注释和 `Tests/UI` 里的规则测试为准。

## 视觉验收

`xc.sh shot` 的用法、调试画面与演示库、隔离的 Pi 目录见 [verify.md](verify.md)。

### 性能测量

入口是 `apple/scripts/perf-mac.sh`，方法与坑见 [verify.md](verify.md)；渲染性能的约束（含不用渐变描边）见 [ui.md](ui.md)。

### 交互预算

预算表只在 `InteractionBench.budgets`；口径见 [verify.md](verify.md)。

## 签名与发布

凭据、发布命令、权限、Sparkle 更新、App 图标见 [release.md](release.md)。

## 落地页与设计资源

营销落地页在 `landing/`，说明见 [landing/AGENTS.md](../landing/AGENTS.md)；`design/` 下是品牌定稿、宣传素材与图标脚本。
