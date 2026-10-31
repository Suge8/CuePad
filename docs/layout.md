# 页面结构与布局

导航、栏、浮层、开合与布局稳定的约定和理由；视觉原则与渲染性能在 [ui.md](ui.md)。

## 导航合同

定稿来源：[窄屏 #60](https://github.com/Suge8/CuePad/issues/60)、[宽屏 #61](https://github.com/Suge8/CuePad/issues/61)、[多会话在场 #62](https://github.com/Suge8/CuePad/issues/62)。原型只供外观参考，以下是目标规则；完成界面接线前不把它们当作已验收行为。

- 布局只有窄屏、宽屏；按可用空间选布局，不按操作系统分业务。Mac 用宽屏，iPad 窄窗同手机、宽窗同 Mac。
- 窄屏打开就是 Cue，只有以 Cue 为根的单栈。右滑或 Cue 页左上圆钮开满屏侧栏，左滑或点头像回 Cue；侧栏顶部为项目｜进展，记住选择。Cue 页名牌不随导航换位。底部那一排、三个 tab 栈与 DockMotion 退役。
- 宽屏为会话条、主区、右栏。主区是项目｜进展或一个会话；右栏是 Cue 或一个会话。Cue 只有右栏一份。设置、搜索、归档、回收站与文件页这类辅助去处由主区承接；Mac 编辑浮层仍按原入口呈现。
- 两端共用会话条的分组格：等你是一块赭黄纸，钉在最上；推进中是一块白纸，在条内滚。共用看板状态线、记号与计数。窄屏 60pt 常驻，一屏至少十格；宽屏默认 220pt，一行一个会话（Agent 标志、名字、右端状态），收起为 72pt 图标条。Cue 交活的光点落在对应格子，Cue 页的待回复提示删除。
- 宽屏开合只读一个用户选择，侧栏按钮与原快捷键共用入口。自动收窄只按窗口宽度推出，不改持久值。看板四列最窄 756pt，Cue 至少 400pt，会话每栏至少 420pt；宽条加看板加 Cue 的边界为 1376pt（原型在 1376 宽、1370 窄实测，生产界面仍需验收）。两个会话均分余宽，分隔线不能拖。
- 点会话条、看板卡、通知或深链默认开右栏；⌘ 点、右键“在左边打开”或拖格子到左栏指定左栏。栏头只有标题与 ×；拖标题换边，系统拖放在松手时才修改去处，途中目标淡铺“放在这里”。两个会话换边时交换；把一个已打开的会话从条上开到另一栏时搬过去并替换目标，不复制同一会话。
- 左栏 × 回项目｜进展的浏览落点（之前选过的项目仍是那个项目），右栏 × 回 Cue。打开会话不改浏览选择，不另存“返回来源”。主区是会话或辅助页时，项目｜进展不画选中底。
- ⌃Tab 换两栏实际输入焦点，⌘⌥← / → 把有焦点那栏的会话挪向指定栏，命令在“显示”菜单。键盘焦点由控件系统持有，导航不保存焦点副本；发送只取该回复框绑定的会话 id。
- 看板列头、会话页头归所属栏，不向整个窗口的工具栏抄一份。宽屏右栏输入框使用一行工具条；每个会话草稿按记录 id 保存，换边不重置。

### 状态与入口

`Workspace.navigation` 是唯一导航值：`Navigation.narrow(NarrowNavigation)` 或 `.wide(WideNavigation)`。窄屏只存 `path` 与根上侧栏的 `sidebarOpen`，Cue、项目书架与进展不放进 path；宽屏只存 `main: WideNavigation.Main` 与 `side: SessionRoute?`（nil 是 Cue）。main 分为 `.browse`（直接读持久浏览选择）、`.session`、`.page`（辅助页）；不把浏览选择再复制到 main。读取用 `layout`、`mainRoute`、`sideSession`；窄屏侧栏内容用 `sidebarRoute`（项目段是书架），宽屏返回落点用 `browseRoute`（项目段可恢复项目详情），栈的系统返回绑定 `path`；尺寸变化经 `setLayout`，不用直接另建一套状态。

偏好唯一存在 `AppSettings` 的设备本地 UserDefaults：`navigationPane` 是项目｜进展（首次默认项目），`currentProject` 是项目段上次打开的项目（nil 是书架），`railExpanded` 是宽条选择（默认 true）。`Workspace.navigationPane`、`browseRoute` 与宽屏 `sidebarOpen` 都直接读它；窄屏侧栏开合只在本窗口，不落盘。既有 `progressPane` 仍只管看板｜会话。iPad 不再另存 `splitProject`。

| 入口 | 窄屏 | 宽屏 |
|---|---|---|
| `show` | 会话压到当前栈；其余同 select | 会话进右栏、Cue 清右栏，其余换主区 |
| `select` | Cue 清栈并关侧栏；项目/进展回根开侧栏；项目详情从侧栏上推入，其余从 Cue 推入 | 同 show |
| `push` | 详情继续压栈并保留根侧栏开合，返回落回来源；已有页回到那层，Cue/书架/进展同 select | 同 show，不建第三个栈 |
| `selectPane` | 保存项目｜进展，清栈并展开侧栏 | 保存选择并回浏览主区，右栏不动 |
| `openSession(id, sessionID:, in:)` | 先读页面首帧，再压栈；忽略选边 | 默认 `.side`；`.main` 明确开左栏，已在另一栏就搬过来 |
| `enter(task, session:, in:)` | 有会话同 openSession；否则任务气泡 | 同左，可指定打开会话的栏 |
| `openReplies` | 空列表不动；单个进会话；多个清项目范围、指出会话并进进展 | 同左；单个默认右栏，多个主区进进展，右栏不动 |
| `moveSession(from:to:)` | 不适用 | 源栏不是会话或原地放下不动；两会话交换，否则源回浏览页/Cue |
| `closeColumn` | 不适用 | main 回 browseRoute；side 回 Cue |
| `back` | 弹出栈顶 | 主区回 browseRoute |
| `speakToCue` | 回 Cue 根并请求输入焦点 | 右栏回 Cue 并请求输入焦点，主区保留 |

宽变窄：主区的书架/进展在根侧栏，项目详情或会话先入栈，右栏会话在最上。窄变宽：栈顶会话进右栏，下一页进主区；没有下一页就回浏览落点，栈顶非会话则进主区。转换后只保留新布局，不缓存旧布局，隐藏的会话不报在场。

`shownSessions: [ViewerKeeper.Page]` 表达这个窗口导航上可见的会话，顺序左、右且不重复；窄屏只取栈顶；侧栏在根上，推入页盖住它，只有根侧栏时集合为空。同步层再处理窗口前后台、遮挡、人在不在；两端界面不得自己算一组给 Viewer。Cue 的可见性仍由现有 CueViewing 接点报。

### 阶段二文件归属

| Owner | 独占写入 |
|---|---|
| 窄屏 #60 | `UI/iOS/Dock*.swift`、`Pager*.swift`、`LeaveShot.swift`；新窄屏侧栏/根容器；`Workspace+Narrow.swift`、`UI/iOS/Root.swift`、`Workspace+iOS.swift`；窄屏相关 Debug 驱动 |
| 宽屏 #61 | `UI/macOS/`（含 Workspace+Mac）、`UI/iOS/SplitRoot.swift`、`Workspace+Wide.swift`；新宽屏容器；Mac Debug 驱动与菜单接线 |
| 会话条 Worker | `UI/Shared/Components/` 的新会话条组件，供两端调用 |
| 同步 #62 | Viewer、ViewerKeeper（含 SessionViewing）、CueKeeper、库结构与同步文档 |
| 导航 core | `Navigation.swift`、`Workspace.swift`、`Workspace+Navigation.swift`、`Route.swift`、`AppSettings.swift`、`docs/layout.md`、`docs/ui.md`、`WORDS.md` |

宽屏 Worker 保留 `SplitRoot` 作为 iPad 容器入口，窄屏 Worker 保留 Root 中对它的调用；共享 Cue 页以及已有共用组件的改动由协调者统一接线，两端先交明确需求，不并行修改这些文件。core 文件已冻结，界面 Worker 通过上述入口写导航，不再增加布局模式、tab、agentPanel 或返回栈副本。

阶段二删除：窄屏的 Dock、DockPager、DockMotion、DockBar、DockTabs、DockHandoff、PagerController/PagerArbiter 与 LeaveShot 的旧横翻链路、底边预留和调试驱动；宽屏的 Mac 整页换会话外壳、SessionHeader 抄写与全窗会话工具栏、iPad AgentPanel 外壳与旧 SplitSidebar；共享 CueReplyTip 及仅服务它的接线由协调者删除。保留每个业务页与任务操作，重接到新容器；不要为了保住旧壳给 Workspace 加兼容入口。

## 页面与布局稳定

- 工具栏内容只随用户操作与数据变化，不随滚动位置、尺寸等布局读数变化。几何读数（`onGeometryChange` / `onScrollGeometryChange`）不写回影响自身排版的状态；按宽度切换排版用 `Layout` 或 `ViewThatFits`。违反会形成布局反馈环，`layout-stress.sh` 抓这类环。
- 布局要稳定：容器多大只看它是什么，不看里面填了多少——空、少、满同一套尺寸；可选的那一行没有也占着位置，计数原地换数、不让一行出现又消失。内容一变整块就缩、就跳，用户读作出了什么事，眼睛还得重新找。例：竖屏 iPhone 的进展页四行铺满顶栏到底部，行高只由这段高定，空行、卡多卡少都不改（`PhoneBoard`；横屏同 iPad、Mac 四列：列最窄 160，放不下四列时（如窄窗开着侧栏）横向滚动、最右一列露出一截，`BoardColumns`）；卡留足标题行数、同一列的卡等高（`BoardCardMetrics`）；页顶那一排中间那块玻璃先定高再上玻璃，项目没写介绍也与两侧圆钮同高（`HeaderPiece`）；同样的还有 Mac 项目页顶的介绍行（`ProjectPage`）、置顶项目卡与"更早"行的第二行、会话条的 Cue 头像与名字。列表的条数是内容，行随条数增减；不变的是每一行、每一块自己的尺寸。
- 滚动区内容的边用 `safeAreaPadding`，不用 `contentMargins(…, for: .scrollContent)`：同一棵树里几块滚动区在同一次更新里定内容边距时，SwiftUI 会把一块的边距写到另一块上、之后不改回，安全区的边每次排版重算。滚动条要贴原来的边就用负的 `contentMargins(…, for: .scrollIndicators)` 抵回。唯一例外是清掉系统列表默认顶边的 `contentMargins(.top, 0)`（`RouteView`）：安全区加不出负数。
- 手机输入框里的选择菜单用 `MenuButton`，不用 SwiftUI 的 `Menu`：菜单一开键盘变矮，输入框会掉下去再弹回（理由在它的头注释）。
- 读库的修饰符（`observing`）挂在一个真的视图上，读不出来时可以是 `Color.clear`：订阅等视图出现才启动，什么都不排它就不启动，页面永远空白。
- 顶栏的工具栏项在推入时就建好、之后只换内容，控件随数据置灰而不出现消失：推入转场期间系统不重建工具栏项，换项要等转场结束才显示，标题会晚到近一秒。
- 手机与 iPad 上从顶栏长出的面板（Cue 的名牌、进展页的额度环）只有 `GrowPanel` 一种：同一块玻璃原地长大，点外面收回，不退成系统弹出框（导航栏里的项画不到栏外，所以有面板的页都是根页、那一排页自己画）。两侧圆钮之间放得下就停在手机那一档宽、居中让出圆钮，放不下就铺满、整颗盖住，不露半颗。面板里不放滚动区：会被写上页面滚动区的内容边距（上面滚动区内容的边那条）。Cue 的面板只放 Cue 自己的、会天天变的（列在 `CueNowPanel` 头注释），空、少、满与启用前后一个尺寸；在做的会话从会话条进入；全部会话与历史仍在进展页的会话段。Mac 上开合不逐帧长大（下面"Mac 上开合"那条），额度明细是从额度环长出的气泡。
- Cue 的现状各处读同一份 `CueNow` 与 `CueBeat`，不按画面各算一次。名牌、侧栏、菜单栏与小组件显示数字账；灵动岛常驻的信息取舍与展开布局见 `CueActivityViews`，不能把完整数字账塞进状态栏。App 与菜单栏图标的角标只数等你（`CueNow.needsYou`）。
- 开着时才有的透明接点层（点面板外收起、点别处收回）用 `.transition(.identity)`，收起那一下就撤：跟着收起的动画走的话，它淡完之前还接点按，收起后紧接着点下面的东西会点在它上面（Cue 面板就这样被点开回来过）。
- 设置各端同一页、同一套分组与说法，按要紧排：最上面一组是 Cue（组名是它的名字，只有名字与在哪台 Mac 上运行两行），下面是 iCloud 同步、通知、外观；Mac 设置窗口只有通用与 Agent 两页，Cue 那组在通用页最上面。一项设置只在一处改：用哪个 Agent 与模型只在 Cue 页上。选在哪台 Mac 上运行的菜单各入口同一份（`CueHostMenu`）。
- 沉浸式的栏：页顶那一排与页里钉住的一块（看板列头与手机看板的行头、分段、筛选）都浮在内容上，内容一直滚到它们后面、从玻璃之间和玻璃里透出来。它们后面、下面不加遮罩、渐变、模糊或底色，滚动区也不从它们的下沿开始（那等于把内容裁在下沿）。窗口最顶那一条：Mac 的工具栏那一条同样什么都不垫；iPhone、iPad 的状态栏那一条是系统的渐进模糊，整个窗口一份，顶上最糊、到状态栏下沿减到不糊，不着色、不垫底，时间与电量才不和滚过去的字叠在一起。用户定的，撤回过两次；规矩在 `Bars`。
- Mac 上不用 NSWindow sheet、`NSAlert`、`runModal`（`lint.sh` 查）：开、关都把主线程关在约 300ms 的嵌套循环里。窗口内的浮层只有 `panel`，确认框是 `dialog`；关法、模态与焦点交还在 `Panel+macOS.swift`。
- 气泡（`PanelStyle.bubble`）的来源只有 `BubbleSource` 一份，摆法一份（`BubblePlacement`）：从控件（按钮、圆钮、胶囊）弹出的挂在控件的框上（Mac 用 `bubble(isPresented:)`；手机栏里的圆钮点下按读屏标识量 `ControlAnchor`）；从一行里点开的（任务行、任务行左滑的"更多"）用按下的那一点、按行高让开整行，行成百上千，不给每行挂几何读数。都没有时在窗口上方居中。手机（窄屏）的任务气泡不对着来源，是贴在底部的纸（`bottom`）。
- 看一条任务只有任务气泡（`TaskBubble`）；点任务行与看板卡时，开工了的叶子直接进它的会话、其余开气泡（`Workspace.enter`）：开工后要看的是会话里的进展。Mac 上也不用系统 popover：它是另一扇窗，进程里第一次弹要 85～113ms，关时主窗口重新变回前台窗口，开着时主窗口的快捷键不响应；窗口内的气泡开约 30ms、关 5～7ms（实测）。
- Mac 上开合不逐帧挪位置：位置逐帧变时 AppKit 每帧重排整窗、重算鼠标跟踪区并重设光标，会掉帧十几次。侧栏开合时分栏在按下的那一下不带动画地换到终点、页按新的宽排一次，看得见的滑动由 Core Animation 在渲染端平移分栏的图层，页的左缘贴着侧栏走，动画里主线程没有活（`SidebarSlide`，工具栏里随侧栏摆的项按同一条曲线随侧栏滑；SwiftUI 的偏移与几何效果同样每帧重排，不用），编辑页原地淡入淡出；有字的一块进出场不缩放（理由在 `Bubble.swift`）。
