# 页面结构与布局

## 导航

- 布局只有窄屏、宽屏，按可用宽度选、不按系统分：Mac 是宽屏，iPad 窄窗同手机、宽窗同 Mac。

## 栏头与页顶

- 栏头不放导航，只放 `Workspace` 里已有的状态；读不到页面读的库就不抄一份（那是第二个事实源）。低频操作进"⋯"。
- 系统导航栏只给推入的页：左缘右滑返回是系统的，所以推入页不藏系统导航栏。
- 浮动导航的边缘处理归 `Bars` 与导航容器，不在各页重复：顶部用系统 `soft` 滚动边缘效果，不另加遮罩、装饰底或随滚动变化的状态；用 `fadesUnderHead` 的栏关掉自己的原生顶部边缘效果，避免叠加；预览页例外：栏后面上下都不垫系统的滚动边缘效果，分页（`PreviewPager`，`TabView` 分页那一层由 `PreviewDismissGuard` 关）与缩放的滚动区（`PreviewZoom`）各自关掉。

## 页面与布局稳定

- 栏头与工具栏的内容只随用户操作与数据变，不随滚动位置、尺寸等布局读数变。几何读数（`onGeometryChange`、`onScrollGeometryChange`）不写回影响自身排版的状态；按宽度切换排版用 `Layout` 或 `ViewThatFits`。违反会形成布局反馈环，`layout-stress.sh` 抓这类环。
- 容器多大只看它是什么，不看里面填了多少：空、少、满同一套尺寸，可选的那一行没有也占着位置，计数原地换数。内容一变整块就缩、就跳，用户读作出了什么事。列表的行随条数增减，不变的是每一行、每一块自己的尺寸。会出现的行预留位置或叠在上方（`ChatLiveSlot`、`composerNotice`、`RiseBehind`）。
- 滚动区内容的边用 `safeAreaPadding`，不用 `contentMargins(…, for: .scrollContent)`：同一棵树里几块滚动区在同一次更新里定内容边距时，SwiftUI 会把一块的边距写到另一块上、之后不改回。滚动条要贴原来的边就用负的 `contentMargins(…, for: .scrollIndicators)` 抵回。唯一例外是清掉系统列表默认顶边的 `contentMargins(.top, 0)`（`RouteView`）：安全区加不出负数。
- 读库的修饰符（`observing`）挂在一个真的视图上，读不出来时可以是 `Color.clear`：订阅等视图出现才启动，什么都不排它就不启动，页面永远空白。
- 开着时才有的透明接点层（点面板外收起）用 `.transition(.identity)`，收起那一下就撤：跟着收起的动画走的话，淡完之前它还接点按，紧接着点下面的东西会点在它上面。
- 设置各端同一页、同一套分组；一项设置只在一处改。

## 浮层、菜单与气泡

- Mac 上不用 NSWindow sheet：开、关都把主线程关在约 300ms 的嵌套循环里。窗口内的浮层只有 `panel`，确认框是 `dialog`（`Panel+macOS.swift`）。
- 系统 popover 关时主窗口重新变回前台窗口；窗口内的气泡开约 30ms、关 5～7ms（实测）。
- 菜单一律系统菜单（`contextMenu`、`Menu`），每类对象一份内容；挂菜单的那一层不包在定时重画的容器里。
- 顶栏长出的面板（`GrowPanel`）里不放滚动区：会被写上页面滚动区的内容边距（上面 `safeAreaPadding` 那条）。

## 宽屏开合

宽屏开合不逐帧排版（Mac、iPad 同一套）：会话条、Cue 开合与跨临界宽时几块这一下就到终点、页按新宽排一次，看得见的滑动全是渲染端叠在图层上的偏移，动画里主线程没有活。做法与否决过的方案在 `WideColumnSlide`、`WideSlide` 的头注释。有字的一块进出场不缩放（理由在 `Bubble.swift`）。
