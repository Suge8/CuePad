# 令牌现状与绕开统计

口径同 [audit.md](audit.md)：`apple/App` 的 Swift，不含 `UI/Debug` 与 `Theme` 自身，`//` 之后不算；基线 98c0ad8f7。"绕开"指该经令牌的地方写了数或系统样式。

## 总表

| 令牌 | 出处 | 规模 | lint | 绕开 |
|---|---|---|---|---|
| Palette | `AppGroup/Palette.swift` | 43 个颜色、3 个函数 | 色值、系统色、叠透明度 | 色值 0；注释与 ui.md 矛盾 4 处（选中＝靛青） |
| Typography | `Theme/Typography.swift`（Mac 组） | Mac 36 个、iOS 21 个 | 只查 `.system(size: 数)` | 系统文字样式 105 处（20 处编进 Mac）；`.system(size: 变量)` 14 处；局部枚举里定字号 45 处 |
| Glyph | `Theme/Glyph.swift` | 6 档 | 同上 | 全 App 只用 41 次；箭头（前进、展开、返回）的字号 15 种写法，经 `Glyph` 的 8 处 |
| Spacing | `Typography.swift` 尾部，仅 Mac | 5 个 | 无 | 用 30 次；写死 `padding` 333、`spacing:` 340 |
| 控件尺寸 | `ControlMetrics`、`Chrome`、`RowMetrics` 与 15 个局部枚举 | — | 无 | 写死 `frame` 213；胶囊与钮的高十几种 |
| Motion | `AppGroup/Motion.swift` | 7 个动画、`Spring`／`Glide`／`Fade` 三组参数 | 曲线 | 自写转场 16 处；字面延迟 2 处；提示条时长 2.4 秒 |
| Radius | `Theme/Radius.swift` | 7 档＋`nested` | 数字字面量 | 现算 1 处（`cell / 4`）；不同心 1 处 |
| Elevation | `Theme/Surfaces.swift` | 3 档 | `.shadow(` | 0 |

## 写死的数按归属

| 归属 | 文件数 | padding | spacing | frame | 系统文字样式 | 合计 |
|---|---:|---:|---:|---:|---:|---:|
| 无主（这一轮能动） | 83 | 111 | 123 | 98 | 41 | 378 |
| Mac 组 | 66 | 134 | 149 | 78 | 11 | 376 |
| 手机组 | 34 | 84 | 57 | 36 | 53 | 230 |
| Widget | 2 | 4 | 11 | 1 | 12 | 28 |
| 合计 | 185 | 333 | 340 | 213 | 117 | 1012 |

（合计另含 `offset` 6、`lineSpacing` 3。）`frame` 多是组件自己的几何（面板宽 360、缩略图 64），不一定要进全局令牌，但要变成组件里具名的常量。

值的分布：

- `padding`：16×62、8×39、12×37、10×34、4×33、14×33、6×20、24×20、18×15、20×13、2×11、40×7、3×6，零星 5、7、9、11、13、19、22。
- `spacing:`：6×69、8×66、10×43、4×43、12×40、2×28、5×11、3×11、16×9、1×7、14×5，零星 9、18、22、28。
- 不在 4 点格上、也不是 2／6／10 这几个光学值的 114 处；10 与 14 合起来 145 处，是定值时最大的判断题。

## 同一个事实写在多处

- **栏边**：`Spacing.page`（Mac 24）、`LibraryLayout.margin`（24／16）、`FloatingHeaderLayout.margin` 16、`UnreadableLibraryView.margin`、`CuePage.inset`（24／16）、`CueListMetrics.inset` 16、`CardEditorPage.inset` 24、`PanelLayer.margin` 24，外加 38 处字面 `.padding(.horizontal, 16)`。
- **浮层内边 20**：`ProjectForm`、`SearchPalette`、`SessionAsks`、`Dialog+macOS`、`PanelSearchField`、`CueListPanel` 空态、`PreviewViewer`、`DeliverableLooks`，都是字面量。
- **控件高**：

  | 用途 | Mac | iOS | 出处 |
  |---|---|---|---|
  | 圆钮、玻璃胶囊、一排控件 | 36 | 44 | `ControlMetrics.height`、`Chrome.control`、`FloatingHeaderLayout.height` |
  | 紧凑按钮 | 28 | 32 | `ControlMetrics.compactHeight` |
  | 任务气泡里的胶囊钮 | 28 | 36 | `BubbleMetrics.capsule` |
  | 筛选胶囊 | 28 | 36 | `FilterCapsule`、`FilterChip` 字面量 |
  | 输入框工具排的胶囊 | 30 | 30（命中 44） | `ConfigCapsule` |
  | 落点胶囊 | 24 | 32 | `ChipMetrics` |
  | 新建任务的项目胶囊 | 24 | — | `NewTaskField` 字面量 |
  | 提示条与它的钮 | 34／28 | 44 | `NoticeView` 字面量、`FloatingHeaderLayout.height` |
  | 分段只画图标时 | 30 | 38 | `PaneMetrics.square` |
  | 列表行 | 30～44 | 44～58 | `TaskMetrics.rowHeight`、`Chrome.row`、`LibraryRowMetrics.height`、字面量 48、28 |

- **字号角色**：15 个局部枚举（`TaskMetrics`、`BubbleMetrics`、`PaneMetrics`、`ChipMetrics`、`LibraryRowMetrics`、`BoardCardMetrics`…）里 45 处定字号；iOS 那一半多是 `Font.subheadline.weight(.semibold)` 这类原始样式，因为 iOS 的 `Typography` 没有对应的名字（`chip`、`sectionCount`、`toolbarLabel`、`laneTitle`、`keycap` 只在 Mac）。

## Palette

色值全部在色板里，lint 守得住。要改的是说法：头注释把"选中"列进靛青的用途，`signatureSoft` 的注释写筛选胶囊生效时用它（实际只有拖放落点用），`IconImage.Accent.lit` 写"选中、正在发生"，`WeekdayChip` 写"描一圈靛青"（代码里已经没有）。docs/ui.md 才是选中规则的出处，这几处改成指向它。`ControlButtonStyle.Kind.highlight`（选中底加靛青字）随唯一用处一起删。

## Typography

Mac 按角色给固定字号，iOS 映射到系统文字样式、跟随动态字体，这个分工对。缺口是 iOS 少 15 个角色，组件就在自己的枚举里拼原始样式；共用文件里直接写的系统文字样式编进 Mac 时是系统的小号（`.caption`、`.footnote` 10 点，`.subheadline` 11 点），低于 Mac 的 12 点下限。`.system(size: 变量)` 14 处躲过了 lint（变量不是数字字面量），多是按 `@ScaledMetric` 画图标，应改成 `Glyph` 一档或 `Typography` 的角色。

## Glyph

档是对的，用得太少。箭头最乱：`.forward`、`.expand`、`.back` 的字号写法有 `Glyph.mark`、`.caption2.weight(.semibold)`、`.footnote.weight(.semibold)`、`.caption.weight(.semibold)`、`.caption2.weight(.bold)` 等 15 种。

## Spacing

B0b 已落（`Theme/Spacing.swift`，两端同名、值按平台，4 点格）：

| 名字 | 用途 | Mac | iOS |
|---|---|---:|---:|
| `hair` | 光学校准：记号贴字、几乎挨着的两样 | 2 | 2 |
| `tight` | 控件里的紧挨（数与单位、两颗小钮） | 4 | 4 |
| `glyph` | 图标与旁边的字 | 6 | 6 |
| `item` | 一行里相邻几样、一组里相邻两行、卡与卡、栏头相邻两颗钮 | 8 | 8 |
| `group` | 一块里的几组之间、分组标题到内容 | 12 | 12 |
| `block` | 一块与一块之间（几个账号、几张纸） | 16 | 16 |
| `inset` | 纸、卡、气泡、行里的字离左右边 | 12 | 16 |
| `panel` | 浮层与面板的内边 | 20 | 16 |
| `page` | 一栏的边 | 24 | 16 |
| `section` | 页内分组之间 | 32 | 24 |
| `pageTop` | 页面内容离工具栏下沿（只 Mac） | 24 | — |
| `replyBottom` | 回复框离栏底（只 Mac） | 16 | — |
| `reading` | 阅读栏最宽（宽度，不是空隔） | 760 | 640 |

原来 Mac 的 `toolbarGap` 并进 `item`、`sectionTitle` 并进 `group`。10、14、18 不另开档，按角色就近：组件内部往下取 8／12／16，组与组之间往上取 12／16／24。`Chrome` 的 `rowLead`、`gutter`、`pad`、`cellGap`、`groupGap` 读这里。

## Motion

令牌与 lint 都在。B0a 补了两样（`Motion.pop`、`Motion.Fade.settle`），lint 禁了 `.transition(.scale`：一个"冒出来"的转场（`.scale(0.9)` 加淡入，减弱动态效果时只淡），代替各处 `.scale`（从 0 起违反 ui-craft 的 0.9～0.97 起点）与 `.scale(scale: 0.6)`；一个"等容器落定再淡入"的延迟（`Fade.settle` = 0.12），代替两处字面量。提示条时长是产品取舍，见 audit.md 第 1 条。

## Radius

lint 只认数字字面量，`ProjectStyle` 的 `cell / 4` 漏了（Mac 7.5、iOS 11），取 `Radius.chip` 或 `block`。问题卡里的回答框（`WaitAnswer.swift:204`）与问题卡同为 `card`，内角应随容器走（`Radius.nested`，问题卡的两种底都要声明 `containerShape`）。

## 附：写死最多的文件（≥5 处）

| 文件（相对 `apple/App/Sources/UI`） | 归属 | padding | spacing | frame | 文字样式 | 合计 |
|---|---|---:|---:|---:|---:|---:|
| Shared/Components/CardPicker.swift | 无主 | 7 | 9 | 4 | 4 | 24 |
| ../../Widget/CueActivityViews.swift | Widget（文字样式豁免） | 4 | 9 | 1 | 8 | 22 |
| Shared/Library/LibraryFileParts.swift | 无主 | 5 | 7 | 0 | 2 | 15 |
| Shared/Library/SkillSection.swift | 无主 | 5 | 6 | 0 | 3 | 14 |
| Shared/Components/Composer+Attachments.swift | 无主 | 1 | 3 | 6 | 2 | 12 |
| Shared/Components/PiSessionList.swift | 无主 | 2 | 9 | 1 | 0 | 12 |
| Shared/Library/LibrarySections.swift | 无主 | 2 | 5 | 0 | 2 | 10 |
| Shared/Components/ChatMargin.swift | 无主 | 4 | 2 | 3 | 0 | 9 |
| Shared/Components/Panel+macOS.swift | 无主 | 4 | 2 | 3 | 0 | 9 |
| Shared/Components/Deliverables.swift | 无主 | 3 | 2 | 1 | 2 | 8 |
| Shared/Components/PiConfigCapsules.swift | 无主 | 3 | 2 | 2 | 0 | 8 |
| Shared/Components/PiSlashPalette.swift | 无主 | 3 | 4 | 1 | 0 | 8 |
| Shared/Components/PreviewPager+macOS.swift | 无主 | 3 | 2 | 3 | 0 | 8 |
| Shared/Components/EmptyState.swift | 无主 | 1 | 3 | 3 | 0 | 7 |
| Shared/Components/FileChip.swift | 无主 | 3 | 2 | 1 | 1 | 7 |
| Shared/Components/PiContextGauge.swift | 无主 | 2 | 3 | 2 | 0 | 7 |
| Shared/Components/ProjectScope.swift | 无主 | 2 | 1 | 1 | 3 | 7 |
| Shared/Components/TaskBubble.swift | 无主 | 4 | 0 | 0 | 3 | 7 |
| Shared/Components/ChatFollow.swift | 无主 | 0 | 0 | 4 | 1 | 6 |
| Shared/Components/PreviewFlight+macOS.swift | 无主 | 0 | 0 | 6 | 0 | 6 |
| Shared/Components/PreviewPages+iOS.swift | 无主 | 3 | 1 | 2 | 0 | 6 |
| Shared/Components/TaskBubbleFooter.swift | 无主 | 2 | 3 | 1 | 0 | 6 |
| Shared/Components/WaitAnswer.swift | 无主 | 3 | 3 | 0 | 0 | 6 |
| Shared/Workspace/AgentLinks.swift | 无主 | 0 | 0 | 6 | 0 | 6 |
| ../../Widget/WidgetViews.swift | Widget（文字样式豁免） | 0 | 2 | 0 | 4 | 6 |
| Shared/Components/ArchiveList.swift | 无主 | 1 | 3 | 1 | 0 | 5 |
| Shared/Components/Atoms.swift | 无主 | 1 | 2 | 0 | 2 | 5 |
| Shared/Components/CaptureComposer.swift | 无主 | 2 | 1 | 0 | 2 | 5 |
| Shared/Components/ChatScrubber.swift | 无主 | 1 | 1 | 2 | 1 | 5 |
| Shared/Components/DeliverableLooks.swift | 无主 | 1 | 0 | 4 | 0 | 5 |
| Shared/Components/Dialog+macOS.swift | 无主 | 2 | 2 | 1 | 0 | 5 |
| Shared/Components/FloatingHeader.swift | 无主 | 1 | 2 | 0 | 2 | 5 |
| Shared/Components/PiBubbles.swift | 无主 | 2 | 2 | 1 | 0 | 5 |
| Shared/Components/PiConversationBlocks.swift | 无主 | 0 | 5 | 0 | 0 | 5 |
| Shared/Components/PreviewReplyBar.swift | 无主 | 3 | 2 | 0 | 0 | 5 |
| Shared/Components/UnreadableLibraryView.swift | 无主 | 0 | 1 | 2 | 2 | 5 |
| iOS/Project/CardViews.swift | 手机组 | 10 | 4 | 1 | 9 | 24 |
| iOS/Search/CardSearch.swift | 手机组 | 11 | 7 | 2 | 2 | 22 |
| iOS/Project/CardMorePanel.swift | 手机组 | 6 | 2 | 5 | 7 | 20 |
| iOS/Home/ShelfScreen.swift | 手机组 | 6 | 6 | 4 | 3 | 19 |
| iOS/NavProto.swift | 手机组 | 6 | 2 | 5 | 2 | 15 |
| iOS/Activity/SessionList.swift | 手机组 | 8 | 2 | 3 | 0 | 13 |
| iOS/Settings/ConflictsScreen.swift | 手机组 | 3 | 5 | 1 | 4 | 13 |
| iOS/Project/ProjectScreen.swift | 手机组 | 5 | 2 | 2 | 1 | 10 |
| iOS/Settings/SettingsScreen.swift | 手机组 | 0 | 1 | 0 | 9 | 10 |
| iOS/Tasks/BoardRowLane.swift | 手机组 | 0 | 4 | 0 | 5 | 9 |
| iOS/Tasks/ProgressScreen.swift | 手机组 | 4 | 2 | 3 | 0 | 9 |
| iOS/Project/FolderCandidates.swift | 手机组 | 2 | 2 | 1 | 3 | 8 |
| Shared/Components/QuotaGauge.swift | 手机组 | 0 | 6 | 0 | 0 | 6 |
| Shared/Components/SessionRailCell.swift | 手机组 | 2 | 2 | 2 | 0 | 6 |
| iOS/NoticeBanner.swift | 手机组 | 3 | 1 | 1 | 1 | 6 |
| iOS/Activity/NewSessionInput.swift | 手机组 | 2 | 2 | 0 | 1 | 5 |
| iOS/Search/SearchCapsule.swift | 手机组 | 3 | 2 | 0 | 0 | 5 |
| Shared/Cue/CueRunPanel+macOS.swift | Mac 组 | 13 | 11 | 7 | 0 | 32 |
| macOS/Search/SearchPalette.swift | Mac 组 | 12 | 7 | 7 | 0 | 26 |
| Shared/Cue/CueNowPanel+iOS.swift | Mac 组 | 3 | 13 | 3 | 5 | 24 |
| macOS/SetupPanel.swift | Mac 组 | 12 | 8 | 3 | 0 | 23 |
| Shared/Cue/CueListPanel.swift | Mac 组 | 7 | 2 | 7 | 0 | 16 |
| macOS/Project/OlderList.swift | Mac 组 | 4 | 4 | 4 | 0 | 12 |
| macOS/Project/CardWall.swift | Mac 组 | 6 | 2 | 3 | 0 | 11 |
| Shared/Cue/CueSchedulePage.swift | Mac 组 | 3 | 3 | 2 | 1 | 9 |
| macOS/Search/SessionResults.swift | Mac 组 | 7 | 2 | 0 | 0 | 9 |
| macOS/Settings/SettingsView.swift | Mac 组 | 1 | 5 | 3 | 0 | 9 |
| macOS/Trash/TrashPage.swift | Mac 组 | 3 | 4 | 2 | 0 | 9 |
| Shared/Cue/CueMacSteps+iOS.swift | Mac 组 | 1 | 5 | 2 | 0 | 8 |
| Shared/Cue/CueWelcome.swift | Mac 组 | 1 | 6 | 0 | 1 | 8 |
| macOS/Sidebar/NewSession.swift | Mac 组 | 4 | 4 | 0 | 0 | 8 |
| macOS/Sidebar/Sidebar.swift | Mac 组 | 4 | 3 | 1 | 0 | 8 |
| Shared/Cue/CueBarView.swift | Mac 组 | 2 | 4 | 1 | 0 | 7 |
| Shared/Cue/CueMemoryPage.swift | Mac 组 | 3 | 4 | 0 | 0 | 7 |
| Shared/Cue/CueQuestion.swift | Mac 组 | 0 | 7 | 0 | 0 | 7 |
| Shared/Cue/ScheduleEditor.swift | Mac 组 | 2 | 5 | 0 | 0 | 7 |
| macOS/Editor/CardEditorBar.swift | Mac 组 | 1 | 3 | 3 | 0 | 7 |
| macOS/MainWindow.swift | Mac 组 | 3 | 0 | 4 | 0 | 7 |
| macOS/Project/SelectionBar.swift | Mac 组 | 3 | 1 | 3 | 0 | 7 |
| Shared/Components/TaskBoardParts.swift | Mac 组 | 3 | 2 | 1 | 0 | 6 |
| macOS/NoticeView.swift | Mac 组 | 3 | 1 | 2 | 0 | 6 |
| macOS/Project/FocusBand.swift | Mac 组 | 3 | 3 | 0 | 0 | 6 |
| Shared/Cue/CueBubble.swift | Mac 组 | 3 | 2 | 0 | 0 | 5 |
| Wide/WideRail.swift | Mac 组 | 2 | 3 | 0 | 0 | 5 |
| macOS/ReplyNoteLayer.swift | Mac 组 | 3 | 1 | 1 | 0 | 5 |
| macOS/Search/SearchPalette+Filters.swift | Mac 组 | 1 | 3 | 1 | 0 | 5 |
| macOS/Settings/SyncRow.swift | Mac 组 | 0 | 3 | 2 | 0 | 5 |
