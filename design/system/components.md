# 重复组件与合并后的接口

每组写：现在有哪几份、合成哪一个、接口长什么样、调用处在谁的路径里。标"已落"的接口在代码里（B0a），以代码与它的头注释为准；其余是 B0b 的草案。一组只留一个实现。值见 [tokens.md](tokens.md)，批次见 [migration.md](migration.md)。

## C1 按钮

现在：`ControlButtonStyle`（primary、highlight、secondary、quiet、circular、glass，另有 `compact: Bool`）是正身；绕开它的有任务气泡的"去会话""开始"、定时的"好"、Mac 提示条的 `NoticeActionButton`、iOS 提示条的动作、Mac 浮层的 `PanelCloseButton` 与记忆页的问号（手画 26 点淡底圆）；`EmptyStateButton`、`settingButton(primary:)` 只是换个名字。

已落（`Theme/Controls.swift`）：`ControlSize`（`inline`／`compact`／`regular`，各自的 `height`、`font`、`padding`，与 `ControlSize.target`：Mac 28、iOS 44），`ControlButtonStyle(kind:size:)`，`ControlSurface(kind:size:selected:)`。高：Mac 24／28／36，iOS 32／36／44。

- `circular` 是玻璃圆钮（浮在内容上）；新增 `round` 是纸与面板上的淡底圆钮（玻璃不叠玻璃），替手画的关闭与问号。
- `selected` 是全 App 那一套选中（选中底、墨字半粗、无描边），只给带字的胶囊（经 `chip`）。
- 旧的 `compact: Bool` 照旧画旧高（iOS 32），迁到 `size: .compact` 时 iOS 变 36，交付说明写明；W2-9 删 `compact`、`highlight`（选中底加靛青字，违反"选中只有一套"）、`EmptyStateButton`、`settingButton`。
- 调用处：无主 `TaskBubbleFooter`、`UnreadableLibraryView`、`EmptyState`、`Panel+macOS`；Mac 组 `ScheduleEditor`、`NoticeView`、`CueListPanel`、`CueStarters`、`CueNowPanel+iOS`、`SettingRow` 的用处；手机组 `NoticeBanner`、`SessionList`。

## C2 胶囊

现在 7 份：iOS 搜索的 `FilterChip`（纸底细边、36 高、`.subheadline`）、Mac ⌘K 的 `FilterCapsule`（淡底、28 高、`meta`）、落点 `DestinationChip`（`ChipMetrics` 24／32）、输入框工具排的 `ConfigCapsule` 一族（模型、Agent、加速、上下文、思考，30 高）、`NewTaskField` 的项目胶囊（24 高、字面量）、定时的 `WeekdayChip`、项目范围 `ProjectScope` 选中时手画的底。

已落（`Components/Chip.swift`）：`chip(on:menu:size:)`，外形就是 `ControlSurface(kind: .secondary, size:, selected: on)`，`menu` 时末尾一枚 `Chevron(.expand)`。按钮外面套 `PressStyle()`，菜单的标签直接挂。

- 关着与次按钮同一种安静底（淡底加发丝边），开着是中性选中底加墨字半粗，与分段同一套选中（已定）。iOS 搜索页的纸底细边随 W2-1 去掉。
- `ChipRow`（横滑一排、右缘渐隐）是容器，留着。
- 删 `FilterChip`、`FilterCapsule`、`ChipMetrics`、`ConfigCapsule`／`configCapsuleHeight`。

## C3 分段

现在：`PaneSegment` 是 App 内的分段（项目｜进展、看板｜会话、规则｜技能、搜索范围）；系统 `.segmented` Picker 三处——外观 `ThemePicker`、定时的重复（`ScheduleEditor`）、同名技能的几份（`DuplicateBar`）。同一屏能同时看到两种选中块。

合成（已定）：App 内的两处换 `PaneSegment`；外观在系统设置表单里，留系统分段。`SearchScopePanes` 手写的"槽"（`padding(PaneMetrics.inset)` 加淡底胶囊）收成 `PaneSegment` 的一个底样式，调用处不再自己垫。`Panes.swift` 在手机组路径里，等合并后改。

## C4 节头

现在：`SectionTitle`（`Typography.sectionTitle`）、`SectionHeader`（自己写 `.headline` 与 `.footnote`，编进 Mac 是 13／10 点）、`SectionLabel`（小号半粗淡墨，可带图标），外加 `OlderGroupHeader`、`SessionList.header`、`SessionResults.header`、`CardPicker.header`、`OlderList.section`、`TrashPage.group` 手写。

已落（`Components/Atoms.swift`）：`SectionHeader(_ title: Dotted | LocalizedStringResource, level: .page | .group, count:, icon:)`。`page` 是 `Typography.sectionTitle` 加计数，`group` 是 `Typography.label` 淡墨可带图标。旧的 `SectionHeader(title:count:)` 画旧样子，与 `SectionTitle`、`SectionLabel` 留到 W2-9。

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

已落（`Components/LinkRow.swift`，B0b）：`LinkRow(title:value:alert:chevron:icon:trailing:)` 只是行的内容，外面套 `Button`／`NavigationLink` 加 `.buttonStyle(.row)`。高 `RowMetrics.height`（Mac 32、iOS 44，`Chrome.row` 就读它）。Cue 面板三行升到 44、面板随之变高（已定，接受）；面板"空、少、满一个尺寸"仍要守住，W2-3 拍空与满两种核对。

## C6 分组纸与分隔线

现在：行拼成纸只有 `rowPaper` 一份，但 iOS"更早"的行在懒加载列表里各自成项、只能手拼首尾圆角（`CardViews.swift:101`）；Mac 接入面板的 `SetupPanel.group` 又仿了一份设置分组。分隔线三种写法：`Divider()`、`Rectangle().fill(palette.hair).frame(height: 1)` 加手写 `.padding(.leading, 40)`、库页 `Divider().padding(.leading, 三个常量相加)`。

合成（已定）：列表行之间不画分割线，靠间距与纸分组，不建 `Hairline`；上面三种写法一律删。系统 `Form` 的设置页保持系统默认；菜单里的 `Divider()` 是菜单分组，不动。`SetupPanel.group` 换 `rowPaper`、不带线。iOS"更早"手拼首尾圆角的理由（懒加载）写在它头注释里，圆角保留、线删掉。

## C7 提示条

现在：同一个 `Workspace.notice`，Mac `NoticeView`（34 高、`.move(edge: .top)` 转场、动作 28 高）与 iOS `NoticeCapsule`（44 高、按字长三档排、`.buttonStyle(.plain)`）两份。

合成：一个 `NoticeCapsule`，平台只差高（`ControlSize.regular`）与摆在哪（由宿主给）；进出场 Mac 原地淡、iOS 从顶边进。时长策略放 `Workspace+Notice`（已定）：普通结果 4 秒，带动作（撤销、归档）或出错 8 秒；指针悬停、键盘焦点、读屏焦点在提示上时暂停计时，读屏开着时不自动收。

## C8 说明气泡

现在：技能与规则的 `LibraryHelp`（经气泡）、记忆与定时的 `CueListHelp`（系统 popover、Mac 上 26 点手画圆）、上下文用量 `PiContextGauge` 的明细（系统 popover）；另有编辑页变量 `VariablesForm`（系统 popover）。

已落（`Components/HelpButton.swift`）：`HelpButton(kind: .round, size: .compact) { 说明 }`，两端经 `bubble(isPresented:)`（手机的气泡也画在场景根那一层 `panelHost`）；页顶那一排给 `kind: .circular`。

变量与上下文明细不是问号，直接改挂 `bubble(isPresented:)`。

## C9 空态

`EmptyState` 是正身，`BlankChat`、`CueWelcome`、`UnreadableLibraryView` 都经它；`EmptyWallTile`、看板列里的虚线空卡、`QuotaEmpty`、记忆页空态是行内的小空态，刻意不同、不并。要改的只是 `EmptyState` 里的字面量（吉祥物 104、最宽 420、内边 24、间距 16／6）变成具名常量或 `Spacing`，以及 `EmptyStateButton` 并进 C1。

## C10 新建任务一行

现在：共用的 `NewTaskField`（只画入口、点了才建输入框，Mac 可换项目）与 iOS 进展页的 `NewTaskLine`（一直是输入框、`DestinationChip` 换项目）。

合成：`NewTaskField` 一个，`choosesProject` 两端都给（iOS 经 `MenuButton`，见 docs/layout.md 手机输入框里的菜单），项目胶囊用 C2。删 `NewTaskLine`。调用处：`ProgressScreen`、`ProjectScreen`（手机组）、`TaskBoardParts`（Mac 组）。

## C11 记号点

现在：书架"设置"行尾 7 点圆、Cue 面板"技能与规则"用 `CueDot.size`、回到最新钮角上 10 点加桌面色描边、灵感卡角的 `AgentDot` 圈 8 点。

已落（`Components/Marks.swift`）：`StatusDot(color:rim:)`，7 点一种尺寸，`rim` 是压在别的图形上时描的一圈底色。`CueDot` 的尺寸改读它（W2-6）。

## C12 箭头

现在 15 种写法（tokens.md「Glyph」）。已落（`Components/Marks.swift`）：`Chevron(.forward | .expand | .back)`，字号只经 `Glyph.chevron`（11 半粗），颜色随外层，读屏跳过。

## C13 单行输入条

`Composer` 是正身（会话回复、对 Cue 说、随手记、新会话、发给 Agent）。另有几块自己画的单行玻璃输入：全屏预览底部的 `PreviewReplyBar`、问题卡里的 `WaitReply`、记忆与定时页底部"记一条"、回复框锁住时的 `PiReplyBar.notice`，各自写 `glass(in: .rect(cornerRadius: Radius.field))` 与内边。是否抽一个只管外壳的 `FieldCapsule`（玻璃、圆角、内边、右边一格发送钮）要看 `Composer` 的量高逻辑能不能不进来：派强模型判断，只列不排批。

## C14 局部尺寸枚举

B0 之后各枚举只留组件自己的几何（具名），字号进 `Typography`、间距进 `Spacing`、高进 `ControlSize`：

| 枚举 | 留下 | 搬走 | 路径归属 |
|---|---|---|---|
| `ChipMetrics`、`ConfigCapsule` | — | 整个删（C2） | 无主 |
| `BubbleMetrics` | 列宽、圈位等几何 | 字号已改读角色（B0b）；`capsule` → `ControlSize.compact`；内边进 Spacing（W3-2） | — |
| `TaskMetrics`、`BoardCardMetrics` | 圈、列宽与卡的几何 | 字号已改读角色（B0b） | — |
| `LibraryLayout`、`LibraryRowMetrics` | 列宽 680、纸的形状 | 栏边 → `Spacing.page`；行高 → `RowMetrics.height`；字号进 Typography | 无主 |
| `PaneMetrics` | `inset`、`square`（读 `ControlSize.regular`） | 字号已改读 `toolbarLabel`（B0b） | — |
| `FloatingHeaderLayout` | `largestType` | 边已读 `Spacing.page`（B0b）；高 → `ControlSize.regular` | — |
| `CueListMetrics`、`ScheduleMetrics`、`BoardCardMetrics` | 几何 | 字号、间距 | Mac 组 |
| `BoardRowMetrics` | 几何 | 间距 | 手机组 |
| `ComposerMetrics`、`ChatLayout`、`DocumentLayout` | 全部（量高与对话排版的几何） | — | 无主 |
