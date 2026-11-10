# 页面结构与布局

只记代码里看不出的约定与理由。每一页放什么、哪个钮在哪以视图代码为准，这里不复述；视觉原则与渲染性能在 [ui.md](ui.md)。

## 导航

- 布局只有窄屏、宽屏，按可用宽度选、不按系统分：Mac 是宽屏，iPad 窄窗同手机、宽窗同 Mac。导航只有 `Workspace.navigation` 一份（`Navigation.swift`、`Workspace+Navigation`、`+Narrow`、`+Wide`），偏好在 `AppSettings`。
- 宽屏三栏的尺寸、临界宽、窗口变窄先收哪栏只在 `WideMetrics`，外框的数在 `Chrome`：只看窗口宽与用户的两个开合选择，换页时栏不动；自动收起只改呈现、不改选择。
- 会话条两端是同一个组件（`SessionRail`）。宽屏只有开着、藏起两态，没有中间的图标条（同访达、备忘录、邮件）；它贴窗口边、与主区只靠底色分开（`WideRail`）。
- Cue 放不下时的抽屉与右栏是同一块（`CueDock`），跨临界宽不重建。窗口跨过临界宽那一下抽屉关掉，之后再变窄不自己出来（会话条的抽屉同一条规则，`Workspace.fit`）。
- 打开会话不改浏览选择，也不另存返回来源；同一个会话只在一边。哪一行画选中只看 `Workspace.shownPane`。
- 焦点由控件系统持有（`WideFocus` 读真实的第一响应者），导航里不存焦点副本；草稿按记录 id 存，换边不丢。
- 一个窗口里哪些会话看得见只有 `Workspace.shownSessions` 一份，同步层据它处理；界面不另算一组。Cue 页的可见性走 `CueViewing`。

## 栏头与页顶

- Mac 窗口工具栏是空的一条，只给最顶那一排定高、把红绿灯放在中线上；三栏的栏头都在这一排、同一中线、同一种控件高（`Chrome` 头注释）。
- 这一排是标题栏：主区与 Cue 各是嵌着的托管视图，不让标题栏自己拖（不然钮点不进去，`ColumnHostingView`），栏头空处挂系统的拖窗口手势（`windowDragArea`）。
- 栏头不放导航，只放 `Workspace` 里已有的状态；读不到页面读的库就不抄一份（那是第二个事实源）。低频操作进"⋯"。
- 新会话三端只有一个入口（`LaneAdd`）；Mac 的 ⌥⌘N 是同一张表单的快捷键。
- 控件按条件写；出没会挤动同一排旁边的才挂着、只换可见（`keepsPlace`）。
- Mac 的编辑浮层（`Workspace.overlay`）的收起钮与标题由栏头给（`CloseButton`、`OverlayHeader`），页里不另写。
- 手机与 iPad 的页顶只有一种（`floatingHeader`）。根上的页与宽屏栏里的页自己画这一排，系统导航栏只给推入的页：左缘右滑返回是系统的，所以推入页不藏系统导航栏。
- 推入页导航栏里的项在推入时就建好、之后只换内容，控件随数据置灰而不出现消失：转场期间系统不重建这些项，换项要等转场结束才显示，标题会晚到近一秒。
- 浮动导航的边缘处理归 `Bars` 与导航容器，不在各页重复：顶部用系统 `soft` 滚动边缘效果，不另加遮罩、装饰底或随滚动变化的状态；用 `fadesUnderHead` 的栏关掉自己的原生顶部边缘效果，避免叠加。会展开的 Cue 名牌（`hasPanel`）始终留在页面 overlay，不随开合切换视图树。

## 页面与布局稳定

- 栏头与工具栏的内容只随用户操作与数据变，不随滚动位置、尺寸等布局读数变。几何读数（`onGeometryChange`、`onScrollGeometryChange`）不写回影响自身排版的状态；按宽度切换排版用 `Layout` 或 `ViewThatFits`。违反会形成布局反馈环，`layout-stress.sh` 抓这类环。
- 容器多大只看它是什么，不看里面填了多少：空、少、满同一套尺寸，可选的那一行没有也占着位置，计数原地换数。内容一变整块就缩、就跳，用户读作出了什么事。列表的行随条数增减，不变的是每一行、每一块自己的尺寸。会出现的行预留位置或叠在上方（`ChatLiveSlot`、`composerNotice`、`RiseBehind`）。
- 滚动区内容的边用 `safeAreaPadding`，不用 `contentMargins(…, for: .scrollContent)`：同一棵树里几块滚动区在同一次更新里定内容边距时，SwiftUI 会把一块的边距写到另一块上、之后不改回。滚动条要贴原来的边就用负的 `contentMargins(…, for: .scrollIndicators)` 抵回。唯一例外是清掉系统列表默认顶边的 `contentMargins(.top, 0)`（`RouteView`）：安全区加不出负数。
- 手机输入框里的选择菜单用 `MenuButton`，不用 SwiftUI 的 `Menu`：菜单一开键盘变矮，输入框会掉下去再弹回。
- "读不出资料库"的卡一个窗口只有一张：`CatalogGate` 只挂在窗口的根上，挂在每一栏上会并排两三张。
- 读库的修饰符（`observing`）挂在一个真的视图上，读不出来时可以是 `Color.clear`：订阅等视图出现才启动，什么都不排它就不启动，页面永远空白。
- 开着时才有的透明接点层（点面板外收起）用 `.transition(.identity)`，收起那一下就撤：跟着收起的动画走的话，淡完之前它还接点按，紧接着点下面的东西会点在它上面。
- 设置各端同一页、同一套分组；一项设置只在一处改。
- Cue 的现状各处读同一份 `CueNow` 与 `CueBeat`，不按画面各算一次；角标只数等你（`CueNow.needsYou`）。灵动岛放什么见 `CueActivityViews`。

## 浮层、菜单与气泡

- Mac 上不用 NSWindow sheet、`NSAlert`、`runModal`（`lint.sh` 查）：开、关都把主线程关在约 300ms 的嵌套循环里。窗口内的浮层只有 `panel`，确认框是 `dialog`（`Panel+macOS.swift`）。
- Mac 上也不用系统 popover（`lint.sh` 查）：它是另一扇窗，进程里第一次弹要 85～113ms，关时主窗口重新变回前台窗口，开着时主窗口的快捷键不响应；窗口内的气泡开约 30ms、关 5～7ms（实测）。
- 菜单一律系统菜单（`contextMenu`、`Menu`），每类对象一份内容，出现在哪都用它（会话 `SessionActions`，任务 `CardActions`）；挂菜单的那一层不包在定时重画的容器里。
- 自绘的浮出只走 `panel`，点外面、Esc 由它一处关；手机与 iPad 从顶栏长出的经 `ModalHost`，抽屉的在 `DrawerCatcher`。
- 气泡的来源只有 `BubbleSource`、摆法只有 `BubblePlacement`，都画在窗口那一层（`panelHost`）。从控件弹出的挂在控件的框上；从一行里点开的用按下的那一点：行成百上千，不给每行挂几何读数。
- 顶栏长出的面板（`GrowPanel`）里不放滚动区：会被写上页面滚动区的内容边距（上面 `safeAreaPadding` 那条）。导航栏里的项画不到栏外，所以有面板的页都是根页、那一排页自己画。
- 看一条任务只有任务气泡（`TaskBubble`）；开工了的叶子直接进它的会话（`Workspace.enter`）。

## 宽屏开合

宽屏开合不逐帧排版（Mac、iPad 同一套）：会话条、Cue 开合与跨临界宽时几块这一下就到终点、页按新宽排一次，看得见的滑动全是渲染端叠在图层上的偏移，动画里主线程没有活。做法与否决过的方案在 `WideColumnSlide`、`WideSlide` 的头注释，量法在 [perf.md](perf.md)「开合的逐帧量法」。编辑页原地淡入淡出；有字的一块进出场不缩放（理由在 `Bubble.swift`）。
