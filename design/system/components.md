# 重复组件与合并后的接口

每组写：现在有哪几份、合成哪一个、接口长什么样、调用处在谁的路径里。接口是给 B0 落地的草案，名字与档位在 B0 定稿时可调，但一组只留一个实现。值见 [tokens.md](tokens.md)，批次见 [migration.md](migration.md)。

## C1 按钮

现在：`ControlButtonStyle`（primary、highlight、secondary、quiet、circular、glass，另有 `compact: Bool`）是正身；绕开它的有任务气泡的"去会话""开始"、定时的"好"、Mac 提示条的 `NoticeActionButton`、iOS 提示条的动作、Mac 浮层的 `PanelCloseButton` 与记忆页的问号（手画 26 点淡底圆）；`EmptyStateButton`、`settingButton(primary:)` 只是换个名字。

合成：

```swift
/// 控件的尺寸档：一排里只有一种高，相邻的按钮、胶囊、分段、单行输入同高；点得到的边至少 `target`（可见的可以更小）。
enum ControlSize {
    case inline   // 嵌在别的控件里：输入框工具排、落点、行内
    case compact  // 卡与气泡里的钮、筛选、作答
    case regular  // 一排控件：圆钮、玻璃胶囊、页顶
    var height: CGFloat { get }        // 定值见 tokens.md
    static var target: CGFloat { get } // Mac 28，iOS 44
}

struct ControlButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, glass, circular, round }
    var kind = Kind.secondary
    var size = ControlSize.regular
}
```

- `circular` 是玻璃圆钮（浮在内容上）；新增 `round` 是纸与面板上的淡底圆钮（玻璃不叠玻璃），替手画的关闭与问号。
- 删 `highlight`（选中底加靛青字，违反"选中只有一套"）、`compact: Bool`（换成 `size`）、`EmptyStateButton`、`settingButton`。
- 调用处：无主 `TaskBubbleFooter`、`UnreadableLibraryView`、`EmptyState`、`Panel+macOS`；Mac 组 `ScheduleEditor`、`NoticeView`、`CueListPanel`、`CueStarters`、`CueNowPanel+iOS`、`SettingRow` 的用处；手机组 `NoticeBanner`、`SessionList`。

## C2 胶囊

现在 7 份：iOS 搜索的 `FilterChip`（纸底细边、36 高、`.subheadline`）、Mac ⌘K 的 `FilterCapsule`（淡底、28 高、`meta`）、落点 `DestinationChip`（`ChipMetrics` 24／32）、输入框工具排的 `ConfigCapsule` 一族（模型、Agent、加速、上下文、思考，30 高）、`NewTaskField` 的项目胶囊（24 高、字面量）、定时的 `WeekdayChip`、项目范围 `ProjectScope` 选中时手画的底。

合成：

```swift
extension View {
    /// 一颗胶囊的外形：`on` 是选中（selection 底、半粗墨字），`menu` 时末尾一枚展开箭头（`Chevron`），
    /// 高按 `size`、iOS 命中补到 `ControlSize.target`。按钮外面套 `PressStyle()`，菜单标签直接挂。
    func chip(on: Bool = false, menu: Bool = false, size: ControlSize = .inline) -> some View
}
```

- 关着时只有一种底。建议淡底 `fill`（Mac 现状、与工具排一致）；iOS 搜索页的纸底细边是唯一的另一种，要不要并掉需设计判断。
- `ChipRow`（横滑一排、右缘渐隐）是容器，留着。
- 删 `FilterChip`、`FilterCapsule`、`ChipMetrics`、`ConfigCapsule`／`configCapsuleHeight`。

## C3 分段

现在：`PaneSegment` 是 App 内的分段（项目｜进展、看板｜会话、规则｜技能、搜索范围）；系统 `.segmented` Picker 三处——外观 `ThemePicker`、定时的重复（`ScheduleEditor`）、同名技能的几份（`DuplicateBar`）。同一屏能同时看到两种选中块。

合成（需设计判断）：App 内的两处换 `PaneSegment`；外观在系统设置表单里，留系统分段。`SearchScopePanes` 手写的"槽"（`padding(PaneMetrics.inset)` 加淡底胶囊）收成 `PaneSegment` 的一个底样式，调用处不再自己垫。`Panes.swift` 在手机组路径里，等合并后改。

## C4 节头

现在：`SectionTitle`（`Typography.sectionTitle`）、`SectionHeader`（自己写 `.headline` 与 `.footnote`，编进 Mac 是 13／10 点）、`SectionLabel`（小号半粗淡墨，可带图标），外加 `OlderGroupHeader`、`SessionList.header`、`SessionResults.header`、`CardPicker.header`、`OlderList.section`、`TrashPage.group` 手写。

合成：

```swift
/// 一节的头：`page` 是页内大段（最近、更早、现在、历史）带可选计数，`group` 是组头（小号半粗淡墨，可带图标）。读屏是标题。
struct SectionHeader: View {
    enum Level { case page, group }
    let title: Dotted
    var level = Level.page
    var count: Int? = nil
    var icon: Icon? = nil
}
```

能折的组（"更早"按月）由调用处在它旁边放 `Chevron`，节头本身不管开合。

## C5 点进去的行

现在：书架的 `ShelfRow` 与 `ShelfLine`（48 高）、Cue 面板的定时／技能与规则／在哪台 Mac 三行（28 高）、灵感"更多"的 `CardMorePanel.row`（44）、技能与规则的 `LibraryRow`（Mac 44、iOS 58），还有原型里的 `NewProjectRow`。箭头字号各写各的，行尾记号点 7、`CueDot.size` 两种。

合成：

```swift
/// 点了进一页或打开一处的一行：图标一列（定宽）、名字、行尾的值与记号点、箭头。高 `RowMetrics.height`，底经 `RowStyle`，
/// 读屏合成"名字，值"。行尾要放常驻控件（开关）时给 `trailing`，箭头照常。
struct LinkRow<Icon: View, Trailing: View>: View {
    let title: Text
    var value: Text? = nil
    var alert: Color? = nil
    var chevron = true
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing
}
```

`RowMetrics.height`（Mac 32、iOS 44）加在 `Rows.swift`，那是 Mac 组的文件。Cue 面板三行升到 44 会让面板变高，面板"空、少、满一个尺寸"的约束要重新核一次：需设计判断。

## C6 分组纸与分隔线

现在：行拼成纸只有 `rowPaper` 一份，但 iOS"更早"的行在懒加载列表里各自成项、只能手拼首尾圆角（`CardViews.swift:101`）；Mac 接入面板的 `SetupPanel.group` 又仿了一份设置分组。分隔线三种写法：`Divider()`、`Rectangle().fill(palette.hair).frame(height: 1)` 加手写 `.padding(.leading, 40)`、库页 `Divider().padding(.leading, 三个常量相加)`。

合成：去掉还是留（ui-craft 要列表靠间距分组，iOS 分组列表的习惯是留）是设计判断。留就只经一个：

```swift
/// 一组行里两行之间的发丝线：从文字那条竖线起（`inset`），不画在首行之上。
struct Hairline: View { var inset: CGFloat = 0 }
```

`SetupPanel.group` 换 `rowPaper`。iOS"更早"手拼圆角的理由（懒加载）写在它头注释里，保留。

## C7 提示条

现在：同一个 `Workspace.notice`，Mac `NoticeView`（34 高、`.move(edge: .top)` 转场、动作 28 高）与 iOS `NoticeCapsule`（44 高、按字长三档排、`.buttonStyle(.plain)`）两份。

合成：一个 `NoticeCapsule`，平台只差高（`ControlSize.regular`）与摆在哪（由宿主给）；进出场 Mac 原地淡、iOS 从顶边进。时长策略放 `Workspace+Notice`：带动作或出错的留到被下一条顶掉或手动关，其余至少 5 秒，指针停着与读屏聚焦时暂停。时长要你拍板（audit.md 第 1 条）。

## C8 说明气泡

现在：技能与规则的 `LibraryHelp`（经气泡）、记忆与定时的 `CueListHelp`（系统 popover、Mac 上 26 点手画圆）、上下文用量 `PiContextGauge` 的明细（系统 popover）；另有编辑页变量 `VariablesForm`（系统 popover）。

合成：

```swift
/// 问号钮：点开一段说明，从钮上长出的气泡（Mac `bubble(isPresented:)`，手机同一个气泡）。读屏名"说明"。
struct HelpButton<Content: View>: View {
    var kind = ControlButtonStyle.Kind.round   // 页顶那一排用 .circular
    @ViewBuilder var content: Content
}
```

变量与上下文明细不是问号，直接改挂 `bubble(isPresented:)`。

## C9 空态

`EmptyState` 是正身，`BlankChat`、`CueWelcome`、`UnreadableLibraryView` 都经它；`EmptyWallTile`、看板列里的虚线空卡、`QuotaEmpty`、记忆页空态是行内的小空态，刻意不同、不并。要改的只是 `EmptyState` 里的字面量（吉祥物 104、最宽 420、内边 24、间距 16／6）变成具名常量或 `Spacing`，以及 `EmptyStateButton` 并进 C1。

## C10 新建任务一行

现在：共用的 `NewTaskField`（只画入口、点了才建输入框，Mac 可换项目）与 iOS 进展页的 `NewTaskLine`（一直是输入框、`DestinationChip` 换项目）。

合成：`NewTaskField` 一个，`choosesProject` 两端都给（iOS 经 `MenuButton`，见 docs/layout.md 手机输入框里的菜单），项目胶囊用 C2。删 `NewTaskLine`。调用处：`ProgressScreen`、`ProjectScreen`（手机组）、`TaskBoardParts`（Mac 组）。

## C11 记号点

现在：书架"设置"行尾 7 点圆、Cue 面板"技能与规则"用 `CueDot.size`、回到最新钮角上 10 点加桌面色描边、灵感卡角的 `AgentDot` 圈 8 点。

合成：`StatusDot(color:)`，一种尺寸；压在别的图形上时的描边是它的参数。`CueDot` 的尺寸改读它。

## C12 箭头

现在 15 种写法（tokens.md「Glyph」）。合成：`Chevron(.forward | .expand | .back)`，字号只经新加的 `Glyph.chevron` 一档，颜色随外层。

## C13 单行输入条

`Composer` 是正身（会话回复、对 Cue 说、随手记、新会话、发给 Agent）。另有几块自己画的单行玻璃输入：全屏预览底部的 `PreviewReplyBar`、问题卡里的 `WaitReply`、记忆与定时页底部"记一条"、回复框锁住时的 `PiReplyBar.notice`，各自写 `glass(in: .rect(cornerRadius: Radius.field))` 与内边。是否抽一个只管外壳的 `FieldCapsule`（玻璃、圆角、内边、右边一格发送钮）要看 `Composer` 的量高逻辑能不能不进来：派强模型判断，只列不排批。

## C14 局部尺寸枚举

B0 之后各枚举只留组件自己的几何（具名），字号进 `Typography`、间距进 `Spacing`、高进 `ControlSize`：

| 枚举 | 留下 | 搬走 | 路径归属 |
|---|---|---|---|
| `ChipMetrics`、`ConfigCapsule` | — | 整个删（C2） | 无主 |
| `BubbleMetrics` | 列宽、圈位等几何 | `strong`、`meta`、`laneFont` 进 Typography；`capsule` → `ControlSize.compact`；内边进 Spacing | 无主 |
| `TaskMetrics` | 圈与列宽 | `caption`、`lineFont`、`stepFont` 进 Typography | 无主（同文件的 `BoardCardMetrics` 归 Mac 组） |
| `LibraryLayout`、`LibraryRowMetrics` | 列宽 680、纸的形状 | 栏边 → `Spacing.page`；行高 → `RowMetrics.height`；字号进 Typography | 无主 |
| `PaneMetrics` | `inset` | 字号、内边 | 手机组 |
| `FloatingHeaderLayout` | `largestType` | 高 → `ControlSize.regular`；边 → `Spacing.page` | 无主，但属页顶外框，等合并后 |
| `CueListMetrics`、`ScheduleMetrics`、`BoardCardMetrics` | 几何 | 字号、间距 | Mac 组 |
| `BoardRowMetrics` | 几何 | 间距 | 手机组 |
| `ComposerMetrics`、`ChatLayout`、`DocumentLayout` | 全部（量高与对话排版的几何） | — | 无主 |
