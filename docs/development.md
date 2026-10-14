# CuePad 开发文档

本文只记代码、注释和 `--help` 看不出的约定、理由与坑；界面行为的规格在各视图文件的头注释里，这里不复述。

## 环境与命令

需要 Xcode 27。入口是 `apple/scripts/xc.sh`（用法见脚本头注释）；共用 Swift 包在 `apple/CuePadKit`，直接用 SwiftPM。

```bash
apple/scripts/xc.sh test mac
apple/scripts/xc.sh test ios        # App 测试里 iOS 也编译的部分，再加 CuePadKit 在模拟器上的测试（手机编辑器的粘贴、分割线、选区、输入法组合、动态字体只在这里跑；带收窄参数时只跑前者；摘要里的 "Executed 0 tests" 只数 XCTest，Swift Testing 不在内）
apple/scripts/xc.sh test mac -only-testing:CuePadTests/<套件>   # test 后的参数原样传给 xcodebuild，用来收窄
cd apple/CuePadKit && swift test
cd apple/CuePadKit && swift build -c release --product cuepad   # 命令行
```

并行的 agent 各设 `CUEPAD_DERIVED=/tmp/<名字>`，截图用的隔离库与 Pi 目录随之落在该目录下。

编译报"没有这个成员"但代码里明明有，或改了 CuePadKit 里公开类型的存储属性之后 App 一启动就崩在 Kit 的释放里（依赖它的模块没重编，还按旧的内存布局读），都是旧的模块缓存：删掉 `<产物目录>/Build/Products/<平台>/Cue*.swiftmodule` 再编，仍不行就换一个空的产物目录整编。

## 代码地图

模块边界由 `Package.swift` 声明，模块表在 AGENTS.md。App 工程的源码目录是文件夹同步组，增删文件不用改工程文件；例外是 `CuePadKit/Tests/CuePiTests/FakeExtension.swift`，Xcode 工程直接引用它（CuePadKit 的桥测试与 App 测试共用）。

## 约定

**资料库位置与隔离。**
- 位置只经 `CueStore` 的 `LibraryLocation` 取，App、命令行与测试同一份规则。
- 环境变量 `CUEPAD_LIBRARY_DIR`（绝对路径）指向隔离目录：资料库、偏好设置（主题、快捷键、上次打开的项目、窗口位置）都放进去，不碰真实的 `com.sugeh.cuepad` 偏好域，并行实例互不影响。
- Mac 上只有正式版（Developer ID 签名的 App 与随它分发的命令行）能打开真实资料库；本机构建（`xc.sh`、测量构建、Xcode 直接运行、`swift build` 编的命令行）不给 `CUEPAD_LIBRARY_DIR` 就报错不打开：没发布的代码一打开就会升级库结构、改写数据并同步出去，正式版之后就打不开了。
- 资料库打不开（更早或更新版本建的库、损坏）时不终止进程，也不换成空库：入口 `AppServices.openLibrary(at:)` 抛 `LibraryFailure`，两端显示 `UnreadableLibraryView`，没有任何写入入口。位置本身有误（没有 App Group 权限、路径不是绝对路径）时 iOS 走同一页，Mac 提示后退出。

**数据。**
- 层级只有 `parentID`，只经 `createTask(_:under:)`、`createCard(body:under:)`、`moveCard` 改，校验在 Store 写入时做；手动顺序用分数索引字符串，避免多设备排序冲突。
- 项目只有一种顺序 `CueStore.projects()`，所有项目列表与选择器都用它。
- 给用户看的任务数只有一处定义 `CueStore.taskCounts`（只计显示在顶层的任务），各处不另算；步骤进度（`subtaskProgress`）与提示词条数只写在上级那一行。
- 空白灵感离开编辑就不留下，收尾只有 `CueStore.dropIfBlank` 一处。
- 提示词送达即用掉，规则只有一处（`PromptConsumption`）：发给会话或开新会话的投送请求写下成功结果的同一个事务里，把它带着的提示词（任务下的灵感，非资料）彻底删掉，任务记下会话、发送记录留快照；删的是行，同步靠下次对账发现。开新会话的请求在等会话记录时改记到任务上，认领的是任务。旧库里已发出去的在 `Schema.upgrades` 第 26 步删。Mac 上提示词的编辑页要处理"卡被删了"（发出去后卡就没了）。
- 软删除只留 `deletedAt`；项目删除时其下的灵感与任务随项目进回收站，由项目推导，不逐条记录来源。
- 设备本地偏好进 UserDefaults，不进同步库；变量上次取值存在那条灵感或任务上并同步。
- 同步记录里的枚举字段读出为 `Open<已知枚举>`：其他版本写入、本版本不认识的值是 `.unknown`，原样写回，不当成已知值；本机只写已知值。
- 界面据 Store 的订阅重读（`CueStore.observe`，页面里用 `observing`；规则见其注释），不在内存复制状态。
- 改表结构：在 `Schema.upgrades` 末尾追加一步并同步改 `create`；升级里任何会因数据冲突失败的语句都会让启动失败，要考虑别的设备已经同步来的数据。

**界面里的项目。**
- 每个窗口一份项目目录 `ProjectCatalog`；名称、图标、计数、目录、⌘1–9 顺序和所有项目选择器都从它同步取，页面与菜单不各自再读。
- 目录读到前根视图不显示页面，所以进入项目页、打开菜单的第一帧就是真实值；顶栏的标题与信息在推入时定下，推入后再改会让整页跳一下，不能等页面数据。
- 项目操作与灵感、任务的操作各只有一份定义（`ProjectActions`、`CardActions`），Mac 右键、iOS 长按与"更多"共用，平台只补各自的发送。
- Mac 上提示词交给哪个 Agent 会话只有一处规则（`Workspace.handOff`）：任务绑着会话就发进那个会话，没绑就在项目文件夹开一个以任务命名的新会话（会话名由 `CueStore.requestLaunch` 按带着的卡定，手机发起的同样）；各个入口都经它，不各自挑会话。
- 绑定文件夹经 `FilePicker`（Mac，非模态，不用 `runModal`）或 `FolderPickerSheet`（手机，经投送请求让 Mac 绑），规则同一份 `ProjectFolders`。

**页面与首次使用（Mac）。**
- 内容区把去过的页挂着（`PageStack`，留几页见 `MacPages`），切页只换哪一页看得见；页里的订阅用 `observing`，不在前台时自动暂停。
- 整个窗口一份的数据页面直接读、不各自订阅：`Workspace.agentLinks`、`folderGuide`；整个 App 一份的此刻有事的会话 `AppServices.liveSessions`。只有按搜索词、项目或分页筛的列表各自查。
- 首次使用才付的一次性成本在启动后空闲时先付掉（`Prewarm`）；新增有首次成本的界面要加进去，加之前量出收益。付一次替身也省不掉的页（Agent 页）直接把真的那一页先挂上（`MacPages.premount`）。
- 会话页的页头全在工具栏上：居中的标题（会话名接状态；绑着任务时同一块玻璃里左边是任务圈、下面一行是"任务 · 步骤"）与右上的"⋯"（当前页的操作：会话页是完成或绑定任务与会话操作，项目页是选择灵感、新建任务与项目操作，其余页置灰），内容区里不另起一行页头。两项都是主窗口常驻的工具栏项，"⋯"每页都在，换页不增删工具栏项、尺寸不变、只换里面的内容（见 `SessionToolbar.swift`、`PageMenu.swift`），标题项的尺寸只随窗口变、不随内容变（尺寸一变整条工具栏重排）。会话页第一圈只出标题、状态与最新的对话，回复框、问题卡与"⋯"的菜单项晚两帧（`NextFrame`）。
- 任务行与提示词行上的会话状态读同步来的会话记录（别的 Mac 上的也有），本机在线的会话在行里换上桥上的实时状态（`Workspace.withLiveState`）；项目页读窗口那一份 `agentLinks`，任务面板读任务看板，不各自只认本机桥。

**图片。** 按内容哈希存文件去重，正文存附件引用。文件经 `CueStore.files` 同步写入（编辑器在主线程直接用）；附件记录（同步载体）由引用它的写入在同一事务里登记，没被引用的图片不上传。缩略图只有 CueEditor 的 `Thumbnails` 一套，派生数据，不落盘不同步。
对话里你的消息带的图片同样是附件：Mac 读会话文件（`PiHistory`）时把图片块存进附件目录，消息正文写成含 `![](cuepad://img/<哈希>)` 的正文格式，`writePiTranscript` 在同一事务里登记附件记录，所以图片随对话同步到手机；对话被清理（`prunePiMessages`）时没人再引用的图片一起回收。已存的旧消息在读会话文件的规则变了之后靠"检查点作废、从头重读"补上（`Schema.upgrades` 里清空检查点的那几步，重读时消息正文内容不同才改写）。

**复制。** `AppServices.copy` 一处，不写发送记录。Mac 上单条目同时放文字与 PNG 时图形应用只取其一，所以含图的正文写成按原顺序含图的 RTFD 并附纯文字兜底（`Clipboard.write`）；iOS 每段文字、每张图片各一个条目。

**预览（Agent 发到手机上看的文件）。**
- Agent 在命令行执行 `cuepad show <文件> [--title 标题]`：不在 Agent 里加别的东西，以后接 Codex、Claude Code 同样是这条命令加同一份 skill。会话由环境变量 `PI_SESSION_ID` 认出，认不出就报错、不猜。
- 预览不是会话文件里的内容：对话仍只来自会话文件，预览卡按创建时间插进对话（`PiChat.entries`）。
- HTML 只读渲染、不联网也读不到别的文件，所以必须是单个文件；`addPreview` 列出页面引用的外部地址，让 Agent 改成单文件再发。否决的方案：在 Mac 上替它内联——样式里的 url()、字体、模块脚本都要处理，漏一类就是静默缺图。

**并发隔离。** App 各目标的默认隔离是主线程（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），类型、协议与函数上不再写 `@MainActor`；要离开主线程才写 `nonisolated`。函数类型（回调参数、`typealias`）不受默认隔离覆盖，需要主线程时照写 `@MainActor`。CuePadKit 没有默认隔离，里面的界面类型照写；它与 App 一样开了 Approachable Concurrency（`Package.swift` 末尾统一设给每个 target），所以 nonisolated 的 async 函数和 async 闭包类型跑在调用方的隔离上，不会自己跳到后台。要离开调用方（启动子进程、同步读写文件、长循环）的，函数或返回的闭包类型上写 `@concurrent`。

**冲突。** iCloud 按记录同步；同一条灵感或任务离线并发编辑时保留两个版本交给用户选择，不静默覆盖。两台设备离线并发挪动可能合成环、任务超过两级、提示词挂在有步骤的任务下或一个叶子下有好几条、有步骤的任务记着会话、挂到灵感下或下级与上级不同项目：应用远端变更后按确定规则收敛（`CardLinks.repairs`；好几条提示词按排序键、id 的顺序并进第一条），各设备算出同一结果并推送。

**编辑器。** 存储格式是纯字符串（`CueFormat`），唯一事实源；保存只经序列化，编辑器内复制输出存储格式。不得访问 `NSTextView.layoutManager` / `UITextView.layoutManager`（一次访问就永久降级到 TextKit 1）。

**Pi 桥。** 协议、版本策略、多客户端、已知边界与 Pi 集成（扩展与 skill 的安装、升级、同意）都以 CuePi README 为准；App 层只有 `PiIntegrationManager` 管首次同意与静默升级，没有第二套状态。实时状态只在内存，历史只来自 Pi 会话文件。什么算历史只在 `PiStateRecorder.exited` 定：一句话没说过的会话（没留下会话文件）关掉后记录直接删掉，不进历史；CuePad 后台托管的会话闲置退出不算结束，记录留着、歇着，仍在"现在"、发话时 Mac 唤醒它，用户在 CuePad 里结束它或终端里的 Pi 退出才进历史。

**命令行。** `cuepad` 随 App 分发在 `CuePad.app/Contents/Helpers/cuepad`，由 `CuePadCLI` 目标构建、随 App 签名与公证；设置里的开关在 `~/.local/bin/cuepad` 建符号链接；隔离模式下建在隔离目录的 `bin/` 里，开发构建不会改到指向正式版的那个链接。`cuepad --help` 是其唯一文档。

**测试。** Swift Testing。
- 测试只用替身或不产生按键事件的系统调用，不向其他应用发送键鼠事件；全局热键的物理触发与跨应用粘贴只能人工验证。
- 用户可见行为的端到端测试从 `Workspace` 的方法走（界面的按钮、菜单调的就是它），断言库、提示与回复框，写在 `App/Tests/UI` 的流程测试里；接线与长相按 [verify.md](verify.md) 的交互验收验。
- App 测试经 `TestApp`（`TestSupport.swift`）拿服务：临时库、独立 UserDefaults、私有命名剪贴板与内存热键；后台托管 Pi 用记录型替身（`RecordingHost`）。
- 等待只有一份（`CueTestSupport`，Kit 与 App 的测试共用）：库里的变化按读取订阅着等（`eventually(store, read)`）；没有事件可订阅的系统异步才用有界条件等待（`eventually { }`）；负向断言（"不会发生"）的固定时长只经 `quietPeriod`。
- iOS 界面级测试把 `IOSRoot` 挂进宿主的窗口，对窗口截图做文字识别来读屏幕上的字：测试里读屏没开，SwiftUI 不生成读屏元素，读不到。
- 与 Pi 的交互走真 `PiBridge` + 假扩展（`FakeExtension`，socket 上说桥协议；socket 路径有 104 字节上限，所以目录在 /tmp 下），不碰真实资料库、`~/.pi` 和其他应用。
- 真实 Pi 与本机 FireCode 的端到端测试（`Real*Tests`）读 `~/.pi` 里装的 FireCode 源码，`CUEPAD_FIRECODE_SOURCE` 指向另一份检出时改读它。

**macOS 壳层。** 窗口（主窗口、设置、资料库读不出的失败页）都在 `WindowFactory` 创建时设好外框：内容铺到透明标题栏下，页面底色通到窗口上沿，不留一条系统色的标题栏；界面不要再在运行时改窗口样式。退出时先等服务收尾再放行，整体最多约 2 秒，卡住的组件不拦着退出、记一条 `shutdown` 日志指出是哪个；收尾的等待不在主线程上（`terminate` 可能在主线程任务里被调用，那时主线程上排队的任务轮不到），所以同步引擎等组件的接口不能隶属主线程。单元测试以 App 为宿主，宿主检测到 `XCTestConfigurationFilePath` 时不启动壳层，避免注册真实全局热键和菜单栏图标。

**iOS / iPadOS。**
- 真机需要开发者账号给 App、分享扩展、小组件、通知服务扩展签上 App Group `group.com.sugeh.cuepad`。
- 资料库始终只有主 App 写：分享扩展把内容放进 `Capture/`，主 App 前台收到进程间通知时入库；小组件与扩展只读主 App 写的 JSON 快照。
- 每个窗口各有自己的导航路径，当前项目只从路径推出（`Navigation.currentProject`）；iPad 侧栏选中的项目存进这个窗口的场景存储，不放全局偏好。
- 有同步时每个窗口出现后请求通知权限并注册远程通知；前台不展示系统通知，前台的提示是 App 内横幅（规则见 [sync.md](sync.md)「Agent 锁屏通知」）。
