# CuePad 开发文档

CuePad 是 Swift 原生应用：macOS 26+、iOS/iPadOS 26+，iCloud 同步，Pi 深度集成。Swift 6 严格并发，界面 SwiftUI，编辑器与菜单栏面板用 AppKit/UIKit。产品定位与功能见 [README.md](../README.md)；模块索引见 [AGENTS.md](../AGENTS.md)。

## 环境与命令

需要 Xcode 26。统一入口 `apple/scripts/xc.sh <build|test|shot> <mac|ios|ipad> [截图路径]`（`ios` 是 iPhone 模拟器，默认 `iPhone 17`，`CUEPAD_IOS_DEVICE` 覆盖；`ipad` 是 iPad 模拟器，`CUEPAD_IPAD_DEVICE` 覆盖），退出码即 xcodebuild 的退出码。共用 Swift 包在 `apple/CuePadKit`，直接用 SwiftPM。

```bash
apple/scripts/xc.sh build mac
apple/scripts/xc.sh test mac
apple/scripts/xc.sh build ios
apple/scripts/xc.sh test ios        # 同一测试目标，跑其中 iOS 也编译的部分（Swift Testing；摘要里的 "Executed 0 tests" 只数 XCTest）
apple/scripts/xc.sh shot mac        # 构建 → 后台启动 → 单窗口截图 → 退出，输出 .derived/shot-mac.png
cd apple/CuePadKit && swift test    # 共用包的全部测试
cd apple/CuePadKit && swift build -c release --product cuepad   # 命令行
```

构建产物在 `apple/.derived/`（自带 `.gitignore`）。**并行的 agent 必须各用一个产物目录**（`CUEPAD_DERIVED=/tmp/xxx apple/scripts/xc.sh …`，截图、隔离库、Pi 目录随之落在该目录下），共用同一个目录时构建与测试会互相覆盖而随机失败。

## 代码地图

`apple/CuePad.xcodeproj` 是一个多平台 App target（macOS + iOS/iPadOS）加分享扩展、小组件与命令行三个目标；源码在 `apple/App/Sources/` 与 `apple/App/Tests/`（文件夹同步组，增删文件不用改工程文件）：

| 路径 | 职责 |
| --- | --- |
| `App/Sources/Shared/AppServices.swift`、`Services/` | 组合根与服务：发送、同步、Pi 扩展管理、命令行工具安装、快照 |
| `App/Sources/macOS/` | 壳层：窗口、全局快捷键、菜单栏图标与面板 |
| `App/Sources/iOS/` | iOS/iPadOS 应用入口与每个窗口的根视图 |
| `App/Sources/UI/` | 界面：`Shared/`（组件、主题、规则、工作区状态）、`macOS/`、`iOS/`、`Debug/`（视觉验收场景与演示数据） |
| `App/AppGroup/`、`ShareExtension/`、`Widget/` | iOS 的 App Group 位置与快照、分享扩展、小组件 |
| `CuePadKit/` | 共用 Swift 包，见下表 |
| `scripts/` | `xc.sh` 与签名、发布脚本 |

| CuePadKit 模块 | 职责 | 平台 |
| --- | --- | --- |
| CueText | 卡片正文的纯文本模型：解析/序列化、分块、变量、光标规范化；只依赖 Foundation | 全部 |
| CueStore | 系统 SQLite3 直连（零第三方依赖）的唯一事实源：表结构（带版本号，别的版本建的库拒绝打开）、仓储、FTS5 搜索、资料库位置、旧库导入；写事务提交后发布变更，跨进程经 Darwin 通知唤醒其他进程的观察者 | 全部 |
| CueEditor | TextKit 2 编辑器：内联图片、分块、变量高亮；AppKit/UIKit 各一层宿主 | 全部 |
| CueSync | 直接用 CKSyncEngine 同步 Store 的记录；图片以 CKAsset 同步；正文用加密字段 | 全部 |
| CueDispatch | 通用投送：权限预检 → 写剪贴板 → 激活目标 → 定向 `Cmd+V` | macOS |
| CuePi | Pi 桥：扩展（随包资源）、socket 客户端、会话历史索引、终端跳转；协议与边界见 [Sources/CuePi/README.md](../apple/CuePadKit/Sources/CuePi/README.md) | macOS |
| CueCLI | `cuepad` 命令行：名词-动词（project/card/task/search/conflicts），默认文本、`--json` 给 agent；只经 Store 公开接口读写，`cuepad --help` 与各命令的 `--help` 是其唯一文档 | macOS |

模块边界由 `Package.swift` 声明；CueStore 依赖 CueText（图片引用、编号），测试共用的支撑在 `Tests/CueTestSupport`。

## 产品模型

功能只服务一条循环：**捕获 → 打磨 → 发出 → 回看**。

| 概念 | 定义 |
| --- | --- |
| 项目 | 卡片的分组；可绑定一个代码目录，Pi 会话与 `cuepad` 命令行按工作目录自动归入 |
| 卡片 | 唯一的内容类型：文字 + 内联图片 + `{{变量}}` + 分块。prompt、思考、目标、笔记都是卡片 |
| 任务 | 独立记录的一行待办，默认全局、可挂到项目；可一键发给 Pi 会话并显示其状态，完成由用户勾选；可与卡片互转（移动而非复制）。不做子任务、截止日期、优先级、提醒 |
| 活动 | Pi 会话的历史索引 + 实时状态，只读，不复制会话原文 |
| 发送记录 | 每次投送/复制自动记录内容快照、目标与时间，可一键重发；即自动日志。已送达而记录没写进去时照样按已发出处理（不重发），但提示没能记下 |

投送目标有两类：**Pi 会话**（经扩展通道直达，支持图文，无需辅助功能权限）与**任意应用**（剪贴板 + 定向 `Cmd+V`，仅文字）。

## 架构约定

- **数据**：ID 用 UUID；排序用分数索引字符串，避免多设备排序冲突；软删除只保留 `deletedAt`，项目删除时其卡片随项目进回收站（由项目推导，不逐卡记录来源）。设备本地偏好（主题、快捷键、自动发送、当前项目）进 UserDefaults，不进同步库。变量上次取值存在卡片上并同步。同步记录里的枚举字段（编号、发送目标种类、Pi 状态、投送方式与状态）读出为 `Open<已知枚举>`：其他版本写入的、本版本不认识的值是 `.unknown`，原样写回，不当成已知值；本机只写已知值。界面据 Store 的观察流重读查询，不在内存复制状态。
- **界面里的项目**：每个窗口一份项目目录 `ProjectCatalog`（有效项目按侧栏顺序、各项目卡片数、本机代码目录），由 `Workspace.observeCatalog` 订阅；项目名称、图标、计数、目录、⌘1–9 顺序、"移到项目"列表都从它同步取，页面与菜单不各自再读。目录读到前根视图不显示页面，所以进入项目页、切换项目、打开菜单的第一帧就是真实值——导航栏标题与副标题在推入时定下，推入后再改会让整页跳一下，不能等页面数据。项目操作与卡片操作各只有一份定义（`UI/Shared/Components` 的 `ProjectActions`、`CardActions`），Mac 右键、iOS 长按与"更多"共用，平台只补各自的发送与绑定代码目录。
- **图片**：按内容哈希存文件去重，正文存附件引用。文件经 `CueStore.files` 同步写入（不经 Store actor，编辑器在主线程直接用）；附件记录（同步载体）由引用它的写入（卡片正文、投送请求、发送记录）在同一事务里为本机已有文件登记，没被引用的图片不上传。缩略图只有 CueEditor 的 `Thumbnails` 一套（编辑器与卡片墙共用、按尺寸缓存），是派生数据，不落盘不同步。
- **冲突**：iCloud 按记录同步。同一卡片离线并发编辑时保留两个版本交给用户选择，不静默覆盖。任务是独立记录而非卡片正文里的清单，勾选只改该条，不与卡片编辑冲突。
- **编辑器**：存储格式是纯字符串，唯一事实源——分块为独占行 `---split---`，图片为行内 `![](cuepad://img/<哈希>)`；运行时二者各为 U+FFFC + 附件，保存只经序列化，编辑器内复制输出存储格式。变量高亮用 `NSTextLayoutManager` 渲染属性（不写 storage、不进 undo），监听 `didProcessEditingNotification` 以覆盖输入法组合期。**禁止访问 `NSTextView.layoutManager`**（会永久降级到 TextKit 1）。附件只挂降采样缩略图并按视口懒加载，原图留在文件。iOS 另写粘贴/拖入委托、光标规范化（改写 `selectedTextRange`）与工具栏"分块"按钮。
- **Pi 桥**：扩展随 App 打包，首次启动征得同意后写入 Pi 扩展目录（要求 Pi ≥ 0.84.4）。实时状态只在内存，历史只来自 Pi 会话文件（只读新增字节，只取会话摘要：名字、工作目录、首条用户消息（标题规则与活动会话同一处：`PiSessionName`）、最后活动；检查点不含正文，存进 Store）。协议、多客户端、版本与已知边界以 CuePi README 为准。
- **发给 Pi**："直接发送"支持文字 + 图片与 steer/followUp；"放进输入框"只有文字，用 `pasteToEditor`（`setEditorText` 会覆盖用户已输入内容），含图片的卡片只能直接发送。图片发原图，Pi 自行缩放（最长边 2000px、base64 ≤ 4.5MB）。发送方式是 Store 里类型化的 `DeliveryMode`（send / steer / followUp / paste，唯一定义），Mac 界面的发送目标与手机发来的投送请求都用它，只在调用 Pi 桥时落成桥的插话/排队：手机经同步下发的投送请求里读到本版本不认识的值时原样保留、Mac 不执行、按失败写回，不静默当成已知值。
- **投送**：进程内 `Dispatcher` actor，经前台应用/剪贴板/按键三个协议接缝测试。顺序靠任务链而非 actor 本身（actor 在 await 处可重入）。激活先订阅通知再调用，超时报错不发键；目标未运行时报错且不动剪贴板。单条目同时放文字与 PNG 时，图形应用只取其一，所以含图卡片写成按原顺序含图的 RTFD 并附纯文字兜底。辅助功能授权归属 CuePad.app。窗口隐藏与发送记录由调用方负责。
- **命令行**：`cuepad` 随 App 分发在 `CuePad.app/Contents/Helpers/cuepad`，由 `CuePadCLI` 目标统一构建、随 App 签名与公证。设置窗口底部的开关在 `~/.local/bin/cuepad` 建符号链接（位置被别的文件占用时不覆盖，App 被移动后能检测并一键修复；不做需要提权的 /usr/local/bin）。它与 App 用同一套资料库位置规则。
- **测试**：Swift Testing 覆盖 Store、同步映射、Pi 会话解析与桥协议、投送队列、命令行；另有"构建 → 运行 → 截图"的视觉验收流程。测试只用替身或不产生按键事件的系统调用，不向其他应用发送键鼠事件；服务测试用临时目录、独立 UserDefaults 与记录型替身，不碰真实资料库、`~/.pi` 和其他应用。全局热键的物理触发与跨应用粘贴只能人工验证。

## 同步

主 App 启动时创建 `CloudSync` 并启动：两个入口（Mac 的 `AppDelegate`、iOS 的 `Launch`）都以 `sync: .iCloud` 构造 `AppServices`，由 `AppServices.makeSync` 按位置与本构建的 iCloud 权限决定（隔离模式 `CUEPAD_LIBRARY_DIR` 与没有 iCloud 权限的本机构建不创建引擎）；该参数没有默认值，测试用 `.custom(替身)`。没有引擎或引擎没能启动时 `syncStatus` 是写明原因的 `.unavailable`，引擎确认账号前是 `.starting`，界面不会显示成"已同步"；未登录 iCloud 或关闭了本 App 的 iCloud 显示 `.noAccount`，文案告诉用户去哪打开（`SyncSummary`）。Mac 启动时注册远程通知，引擎才能收到别的设备改动的静默推送；回到前台、Mac 系统唤醒时立即 `syncNow()`，推送由引擎自己处理。`CloudSync.stateUpdates` 推送"状态 + 问题"快照（状态不变时新增或重复的问题也送达），`AppServices` 据此暴露 `syncStatus`、`syncIssues`，另有 `conflicts` 与 `resolveSync`、`resolveConflict`。待推送的登记由数据库推导：启动、处理同步决定时全量对账；之后每次本机提交只登记这次改动的记录（SQLite update hook 记下的改动行）；别的进程（命令行）写过库、或有登记因配额等失败被搁置时，下一次改动全量对账。Mac 端把 Pi 会话状态写成同步记录（启动时先清掉本机遗留的），并只执行发给本机 `hostID`（硬件 UUID 的哈希前缀）的手机投送请求；执行器读写 Store 失败经 `onIssue` 上报，不吞掉（请求会停在原状态，手机那边一直等）。投送请求的往返时间（`DeliveryRequest.roundTrip`，创建 → 结果回到本机）由发起的设备在应用远端结果时用本机时钟记下，存在同步表的本机列里，不进 CloudKit。

**Pi 锁屏通知**：Pi 会话状态记录带明文可查询的 `notify` 标志（"等你确认"、"完成"的转换那一次写入上置位）。CloudKit 服务端订阅在标志置位时直接生成可见通知，不依赖静默推送与 App 在后台运行；订阅由 iOS 建立（幂等，账号切换时重建），点通知路由到对应会话。通知文案只用本地化 key 的通用句（标题与详情是加密字段，不会出现在通知里）。通知反映服务端收到记录那一刻的状态：标志在上传前被状态已前进的后续写入取代就不送出，同状态的更新则沿用标志——状态记录不是事件日志，要保证每个事件都送达需要单独的追加式通知事件记录，那是另一种设计。该字段的可查询索引由生成的数据结构声明，已部署到生产环境。

### 排查与真机验证

App 自己的日志都在 subsystem `com.sugeh.cuepad`（类别 `services`、`launch`、`shutdown`、`pi-history`）；CloudKit 与 CKSyncEngine 的日志在 `com.apple.cloudkit`：

```bash
log show --last 30m --info --debug --predicate 'subsystem == "com.sugeh.cuepad" OR (process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit")'
log stream --info --predicate 'process == "CuePad" AND subsystem BEGINSWITH "com.apple.cloudkit"'   # 实时看
```

同步是否真在跑，以库为准（只读复制出来看，不碰用户的库）：`syncState` 有一行 `engine`（引擎序列化的状态），`syncRecords` 的行数随推送增长到与同步表记录数相当。真机验证：装发布版 → 打开设置的同步分区，应先显示"正在连接 iCloud…"再变"已同步"（未登录或关掉本 App 的 iCloud 时显示去哪打开）→ 几分钟内复制库检查上面两张表 → 另一台设备上能看到同一批项目与卡片。

### CloudKit 数据结构

数据结构由同步记录映射推出，不手写：`apple/CloudKit/cuepad.ckdb` 是生成物，`CloudKitSchemaTests` 保证它与映射一致；映射改了测试会失败，在 `apple/CuePadKit/` 下用 `CUEPAD_REGENERATE_SCHEMA=1 swift test --filter regenerateSchemaFile` 重新生成，再导入开发环境。管理令牌存在钥匙串 `cuepad-cloudkit-management-token`，不入库、不打印：

```bash
export CLOUDKIT_MANAGEMENT_TOKEN=$(security find-generic-password -a cuepad -s cuepad-cloudkit-management-token -w)
C="--team-id SVPPQJM9JG --container-id iCloud.com.sugeh.cuepad --environment development"
xcrun cktool validate-schema $C --file apple/CloudKit/cuepad.ckdb
xcrun cktool import-schema $C --validate --file apple/CloudKit/cuepad.ckdb
xcrun cktool export-schema $C --output-file /tmp/dev.ckdb   # 回读：服务端把字段按字母序排列并补系统字段，逐类型核对字段与权限
```

开发环境的结构已导入并回读核对，生产环境已部署。生产环境的结构只能增不能删，开发环境导入的结构也不能删去生产已有的字段与类型：已下线的记录类型 `tags`、`cardTags`、`probes` 与字段 `cards.isFavorite` 在生成器里（`CloudKitSchema.retiredTypes` / `retiredFields`）照原样声明，客户端不再读写。生产环境只能在 CloudKit 控制台网页点「Deploy Schema Changes」部署开发环境的结构，所以映射再改时需重复"生成 → 导入开发环境 → 控制台部署"。

## 平台

### macOS 壳层

主窗口在 `MainWindowFactory` 创建时就设好外框（内容铺到透明标题栏下），界面不要再在运行时改窗口样式；设置窗口（⌘,）由 `SettingsWindowController` 承载；`CuePadApplication` 在退出前结束挂在窗口上的弹窗，⌘Q 与 SIGTERM 才不会被 sheet/alert 卡住；退出时先等服务收尾（停止远程投送执行器、同步引擎、Pi 连接与全局快捷键）再放行，整体最多等约 2 秒，卡住的组件不拦着退出、记一条 `shutdown` 日志指出是哪个；收尾的等待不在主线程上、回复经主 run loop 的 common modes 送达（`terminate` 可能是在主线程上的任务里调用的，那时系统在嵌套事件循环里等回复，主线程上排队的任务轮不到），所以同步引擎等组件的接口不能隶属主线程（`SyncControlling` 是 `nonisolated`）；菜单栏面板 `MenuBarPanel` 随内容尺寸变化，顶边固定在图标下方。单元测试以 App 为宿主，宿主检测到 `XCTestConfigurationFilePath` 时不启动壳层，避免注册真实全局热键和菜单栏图标。

### iOS / iPadOS

- 资料库在 App Group 共享容器 `group.com.sugeh.cuepad` 的 `Library/`（库文件、`Attachments/`、待入库的 `Capture/`、给小组件的 `Snapshots/`），偏好用同名 UserDefaults 套件。模拟器直接可用；真机需要开发者账号给三个目标（App、分享扩展、小组件）签上该 App Group。
- 资料库始终只有主 App 写：分享扩展把内容放进 `Capture/`，主 App 在前台、收到扩展的进程间通知时入库；小组件与扩展不打开资料库，只读主 App 写的 JSON 快照。
- 每个窗口（iPad 多窗口）各有一个 `SceneContext`，选中项目不放进全局偏好。
- 有同步时，每个窗口出现后请求通知权限并注册远程通知（`Info.plist` 声明 `remote-notification` 后台模式）；锁屏通知文案按 key 取自 `App/Sources/zh-Hans.lproj/Localizable.strings`。点开通知由 `Sources/iOS/PiAlertCenter.swift` 交给界面：打开活动（iPhone 标签 / iPad 右侧面板）并定位到该会话。

## 视觉

内容是纸，控件是玻璃：编辑器与卡片用安静的实色底并保留纸感品牌；颜色只有纸与墨两种身份——强调色就是墨（主按钮、焦点；选中项是墨色浅底 `selection` 加粗体，Mac 侧栏与 iOS 共用，不用系统灰胶囊），彩色只表示状态（注意橙、失败红）与项目；三层同一色温由深到浅：侧栏 < 桌面 < 纸，深色是"夜里的纸"（暖黑），令牌在 `UI/Shared/Theme/Palette.swift`；动效用无回弹弹簧，时长不超过 300ms，减弱动态效果时退为短淡入淡出（`Motion`）；工具栏、侧栏、弹层、菜单栏面板用系统 Liquid Glass 组件，玻璃不叠玻璃；"降低透明度""增强对比度"开启时自动退回实底。中文正文一律苹方。界面不解释内部规则：分组的依据写在代码里，不写成给用户看的说明文案。

- **Mac 版"近处卡片、远处列表"**：可收起的玻璃侧栏（⌘\），分置顶 / 最近项目 / 全局 Pi 会话（与菜单栏面板同一种行：主行是会话显示名，副行是工作目录名 · 状态），⌘1–9 切项目。资料库读不出来时不给任何写入入口（页面、底部输入栏、卡片纸页、⌘N、搜索、任务面板、新建项目、菜单栏稿纸），只说明原因并给"重试"。项目页三段：顶部"目标与下一步"（项目目标卡 + 该项目未完成任务 + 该项目的 Pi），下滚时收成一行；中间工作集卡片墙（界面上标题就叫"最近"，不向用户解释上墙规则；置顶单列，其余为最近编辑或未发送，只在打开项目或跨天时重排；分列稳定：已有卡不换列，新卡进最短列顶部、同列下移，只有列数变化时整面重排）；下方"更早"按周分组，3 个月以上按月折叠。滚到工具栏下的内容统一淡到桌面色（各滚动页同一个渐隐层），下滚后收成的一行浮在工具栏那一条里，但不放进工具栏；侧栏开合时页面按终点宽度只排一次、被侧栏推着走，不逐帧重排。⌘K 搜索跨项目，按项目/含图片/发送目标/时间筛选；底部玻璃输入栏随手记存卡或直接发给 Pi；卡片连续放大成居中的纸页，关闭时沿原路缩回原卡片；发送按钮只在有内容时出现，发过的卡标纸飞机 + 目标名，没发过的什么都不标；空库首次打开只给一句话和"新建项目"；菜单栏面板是一张小稿纸，⌘↩ 直接发出。设置里有 iCloud 同步状态、"需要你决定"的两种选择和冲突副本；同步需要关注时（没登录 iCloud、需要你决定、出错等）工具栏右上角露一个同步图标，悬停看原因、点开设置，平时不显示。
- **iPhone"项目书架 + 随手记"**：首页是项目书架（置顶项目为大卡，带目标、卡片数、任务数与 Pi 状态点），顶部一行"今天 · N 张"进入按时间的流；标签栏为 项目 / 任务 / 活动，"活动"承载 Pi 状态与"等你确认"（角标 + 推送）；搜索不占标签：书架下拉露出搜索框（或点右上角放大镜）搜全部卡片，项目页下拉只搜本项目，结果与 iPad 搜索页同一套组件；标签栏上方常驻随手记输入栏（首页记入收件箱，项目页记入该项目）；编辑为纸页，键盘上方玻璃工具栏（分块、图片、变量、发送）。
- **iPad**：左栏项目、右侧卡片墙与项目页，任务与活动在右侧面板，编辑时纸页覆盖项目页；外接键盘快捷键与 Mac 对齐。

## 资料库与隔离

位置规则唯一来源是 `CueStore` 的 `LibraryLocation`：macOS 在 `~/Library/Application Support/CuePad/Library/`，iOS 在 App Group 容器；环境变量 `CUEPAD_LIBRARY_DIR`（必须是绝对路径，否则 App 弹窗说明后退出）指向隔离目录，资料库、偏好设置（主题、快捷键、当前项目、窗口位置）都放进去，不导入旧库，不碰真实的 `com.sugeh.cuepad` 偏好域，并行实例互不影响。App、命令行与测试都经它取位置。

macOS 首次启动从旧版（Electron 时代）数据库 `~/Library/Application Support/CuePad/cuepad.db` 导入一次：只读源库的副本（含 `-wal`），映射为新模型，幂等；完成标记是库目录里的 `.electron-import-completed`。

## 视觉验收

`shot mac` 直接启动产物里的可执行文件并记下它的 PID（不经 LaunchServices 激活，不抢焦点；上次中断遗留的实例只按记下的 PID 结束），按该 PID 找窗口 ID 后 `screencapture -l` 只截该窗口（首次需给终端授予屏幕录制权限）；以 SIGTERM 退出，走应用正常退出流程。`shot ios` / `shot ipad` 构建 → 模拟器安装启动 → 截图 → 终止，库与偏好放进 `.derived/library-ios`。`--` 之后是 App 启动参数：

```bash
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark
```

- Debug 构建认 `-CuePadDemo YES`（空库时写入演示数据）、`-CuePadProject <名称>`、`-CuePadScene <collapsed|older|editor|search|tasks|trash|settings|menubar>`、`-CuePadSearch`、`-CuePadCard`、`-CuePadWindowSize 1280x800`、`-CuePadBench <sidebar|motion|resize|churn>`（开合侧栏 10 次 / 存卡后开合纸页，这两项结束自动退出，供 Instruments 或连拍取帧；resize 在侧栏开合途中拉窄窗口，留给截图核对页宽；churn 边加卡边逐点拉宽窗口）、`-CuePadWindowOrigin x,y`（窗口可放到屏幕外）、`-CuePadImport <旧库路径>`（界面起来后导入旧版资料库）、`-CuePadCatalogFailure YES|once`（项目目录读取报错：YES 每次都失败，核对失败画面；once 每个窗口与菜单栏面板只有第一次失败，按"重试"后恢复，核对重试路径），说明见 `App/Sources/UI/Debug/DebugScene.swift`；设置项可直接覆盖（`-theme dark`）。`settings`、`menubar` 画面把设置窗口、菜单栏面板的内容放进主窗口拍，因为只截主窗口。
- `CUEPAD_SHOT_LIBRARY` 换库目录（默认 `.derived/library`），`CUEPAD_SHOT_SETTLE` 是出窗后等待渲染的秒数。
- Pi 目录同样隔离（`.derived/pi-agent`、`/tmp/cuepad-shot-<uid>`），截图不含 `~/.pi` 的会话。隔离的 Pi 目录里没装扩展，侧栏底部出现"连接 Pi"征求同意是正确状态；不要它时传 `-piExtensionDeclinedVersion '<integer>N</integer>'`，N 取 `cuepad-bridge.ts` 里的 `EXTENSION_VERSION`（只写入参数域，不改已保存的设置）。
- 布局反馈环压力场景：`apple/scripts/layout-stress.sh [CuePad.app]`（缺省取 `$CUEPAD_DERIVED` 的 Debug 构建）跑三组隔离实例——屏幕外最小窗口下 Pi 会话快速结束/新建并在思考中/出错间跳、1280×907 下 Pi 全状态轮换、常驻滚动条下边加卡边拉宽，本机有真实 pi 时再加两组真实 Pi 会话「发提示词 → 出错/完成 → 开新会话 → 立刻再发」（`apple/scripts/pi-real-churn.py`，离线假模型 `pi-stress-model.ts`，每轮等上一轮结束再开新会话，会话文件真实落盘，并断言 Pi 会话文件与应用历史确实产生、否则判为没覆盖到）——按进程日志里的 "Geometry action is cycling" 与 "has continued for 300 iterations" 判定，有则退出码 1。检测器自检：`layout-stress.sh --inject-loop` 给每组挂上刻意的几何回写环（`-CuePadGeometryLoop YES`），必须以 1 退出，证明它抓得到这类环。Pi 轮换由 `apple/scripts/pi-churn.py` 假扩展提供。界面约束：工具栏内容只随用户操作与数据变化，不随滚动位置、尺寸等布局读数变化；几何读数（`onGeometryChange` / `onScrollGeometryChange`）不写回影响自身排版的状态，按宽度切换排版用 `Layout` 或 `ViewThatFits` 当场决定。
- 窗口位置/尺寸会被系统记住（`NSWindow Frame main`），截图尺寸以上次为准；恢复默认：`defaults delete com.sugeh.cuepad "NSWindow Frame main"`。

## 签名与发布

本机构建走 ad-hoc 签名（`xc.sh` 覆盖工程默认的团队与身份，并换用不含 iCloud/推送的 macOS 权限文件）；签名事实源是 `App/Config/Signing.xcconfig`。发布与真机构建是手动签名：Xcode 的自动签名用 API 密钥时管不了 App Group 与 iCloud 容器，所以证书与描述文件由 `scripts/provision.py` 经 App Store Connect API 创建，工程里各 target 指定名称（只对 `iphoneos` 与 macOS 的 Release 生效，模拟器与日常构建不受影响）。

凭据文件 `~/.appstoreconnect/cuepad.env`（不入库）的字段：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_PATH`（App Store Connect API 密钥 `.p8` 的路径）、`CUEPAD_TEAM_ID`；`xc.sh release ios` 另需 `CUEPAD_TESTER_EMAIL`（加入内部测试组的 App Store Connect 用户邮箱）。Apple Distribution 证书的私钥放专用钥匙串 `~/.appstoreconnect/cuepad-signing.keychain-db`。缺凭据文件时 build/test/shot 照常，只有下面的发布命令会报错；密钥内容不会打印。

| 命令 | 作用 |
| --- | --- |
| `xc.sh provision` | 幂等：创建 App ID 与能力（App Groups、iCloud、推送）、Apple Distribution 证书、iOS 与 macOS 描述文件 |
| `xc.sh release mac` | 刷新描述文件 → 归档（Developer ID）→ 导出 → `notarytool` 公证 → 装订 → `spctl` 与 `codesign` 校验 → `<产物目录>/release/mac/CuePad-<版本>-mac.zip`，并生成 `appcast.xml`（见「自动更新」） |
| `xc.sh release ios` | 刷新证书与描述文件 → 归档 → 导出 IPA → `altool` 上传 → 建/取内部测试组「内部」并加入账号持有人（构建号取时间戳，自动递增） |
| `xc.sh device` | 登记连接的真机 → Development 证书与描述文件 → 开发构建 → 安装并启动 |
| `scripts/testflight.py builds` | 列出 TestFlight 构建与处理状态 |

权限：主 App 有 iCloud（CloudKit，`iCloud.com.sugeh.cuepad`）、推送（`$(APS_ENVIRONMENT)`：Debug development，Release production）与 App Group（iOS）；扩展只有 App Group；macOS 另有 Apple Events 自动化（终端跳转）。辅助功能权限使 Mac 版不能进 Mac App Store，走官网分发并用 Sparkle 更新。

只能在网页上做的一次性前置：App Group `group.com.sugeh.cuepad` 与 iCloud 容器 `iCloud.com.sugeh.cuepad` 的创建及挂到 App ID；Developer ID Application 证书（账号持有人创建，CSR 由 `provision.py devid-csr` 生成，`provision.py devid-import <.cer>` 导入）；App Store Connect 里的 App 记录。

## App 图标

`App/Sources/AppIcon.icon` 是 Icon Composer 的分层图标（Liquid Glass，浅色/深色/着色三种外观），由 `scripts/make-icon.py` 从品牌 logo `design/final/logo-final.png` 矢量化生成（potrace 描成 SVG，C 与纸片两层；依赖 Pillow 与 potrace）；换 logo 后重跑脚本即可，预览见 `design/final/app-icon-preview.png`。菜单栏模板图仍是 `Assets.xcassets/MenuBarIcon`。

## 自动更新（macOS）

用 Sparkle 2（EdDSA 校验、增量更新），以官方二进制 xcframework 引入：`Vendor/Sparkle/Package.swift` 只有一个 `binaryTarget`（url + checksum，升级版本改这一处），不拉 Sparkle 源码。更新源 `https://cue-pad.com/appcast.xml` 与公钥在 `App/Config/CuePad-macOS-Info.plist`；设置窗口底部有"自动检查更新"开关和"检查更新…"，App 菜单里也有"检查更新…"。隔离模式（`CUEPAD_LIBRARY_DIR`）不启动更新器。

EdDSA 私钥在专用钥匙串（`~/.appstoreconnect/cuepad-signing.keychain-db` 里的 `cuepad-sparkle-ed25519`，不入库；`scripts/sparkle.sh key` 首次运行时生成并打印公钥）。`xc.sh release mac` 用时间戳作构建号（Sparkle 按 `CFBundleVersion` 比较新旧，每次发布必须递增），在公证、装订后把 zip 收进更新历史目录 `~/.appstoreconnect/cuepad-updates/` 并生成 `appcast.xml`（含与历史版本的增量包，所以历史 zip 必须留在这里；它在产物目录之外，清理产物目录或换 `CUEPAD_DERIVED` 不影响），`appcast.xml` 另复制到 `<产物目录>/release/mac/`。更新包的下载地址前缀用 `CUEPAD_UPDATE_URL_PREFIX`（默认 `https://cue-pad.com/downloads/`）；更新历史目录里的 zip、增量包与 `appcast.xml` 部署到对应位置由人决定。

## 落地页与设计资源

营销落地页在 `landing/`（SvelteKit，部署 Vercel，Root Directory 指向该目录），说明见 [landing/AGENTS.md](../landing/AGENTS.md)。`design/final/` 是品牌 IP 与 logo 定稿，`design/promo/` 是宣传图与演示素材的源与合成模板，`design/tools/` 是图标与抠图脚本。
