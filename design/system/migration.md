# 迁移分批

先由一个人落共享边界（B0a 已落、B0b 等 Mac 组合并后），再按文件分批迁移。同一波里的批次文件互不重叠，可以并行；W3 在同目录的 W1／W2 合并后开工。为什么要改、改成什么样见 [audit.md](audit.md) 与 [components.md](components.md)。

路径前缀：`UI/` = `apple/App/Sources/UI/`，`AppGroup/` = `apple/App/AppGroup/`。

## 每批都照做

- 开工前读 docs/ui.md、docs/layout.md、docs/i18n.md 与 [components.md](components.md) 里对应那一组；新文件按职责拆，单文件不超过 20KB（提交钩子）。
- 改法写的是"换成什么"；遇到批次里没写到、要改长相的地方，停下记进交付说明，不自己定。
- 换掉旧写法后同一批里删干净（旧类型、旧常量、因此变空的修饰与注释），完成标准里的 `rg` 为零。
- 本批文件里顺手收的四样（不另开批）：箭头换 `Chevron`、记号点换 `StatusDot`、系统文字样式（`.font(.caption)` 这类）换 `Typography`／`Glyph` 的角色、列表行之间的分割线删掉（菜单里的 `Divider()` 与系统 `Form` 不动）。
- 清掉了 lint 棘轮里的违规就把这个文件从那条规则的例外里删掉（`apple/scripts/lint.sh` 里"棘轮"那三条）。
- 完成标准（每批都要）：`apple/scripts/xc.sh check` 退出 0；`design/system/shots.sh <本批的名字>` 重拍到 `apple/.derived/polish-system/after/`，与基线同名图逐张对看，长相变化只出现在本批说要变的地方；交付说明列出有意的变化。

档：**强**＝需要设计判断或跨文件改接口，派强模型，截图先给你看；**便**＝按表机械替换，便宜模型。

## B0a 共享边界一（强，一人）——已落

只动无主文件。接口是加出来的（expand），旧接口留到 W2-9 一起删（contract）：旧接口的调用处在手机组、Mac 组的文件里，这一轮碰不得。

文件：
- 新 `UI/Shared/Theme/Controls.swift`：把 `ControlMetrics`、`ControlButtonStyle`、`ControlSurface` 从 `Surfaces.swift` 搬过来（那个文件已 17KB），加 `ControlSize` 与 `ControlButtonStyle(kind:size:)`、`Kind.round`、`ControlSurface(selected:)`（[C1](components.md#c1-按钮)）。暂留 `compact:` 与 `.highlight`。
- `UI/Shared/Theme/Surfaces.swift`：删掉搬走的部分。
- `UI/Shared/Theme/Glyph.swift`：加 `chevron` 一档。
- 新 `UI/Shared/Components/Chip.swift`：`chip(on:menu:size:)`，外形经 `ControlSurface`（[C2](components.md#c2-胶囊)）。
- 新 `UI/Shared/Components/Marks.swift`：`Chevron`、`StatusDot`（C11、C12）。
- 新 `UI/Shared/Components/HelpButton.swift`（C8）。
- `UI/Shared/Components/Atoms.swift`：`SectionHeader(_:level:count:icon:)`（C4）；旧的 `SectionHeader(title:count:)`、`SectionTitle`、`SectionLabel` 暂留。
- `AppGroup/Motion.swift`：`Motion.pop`（`.scale(0.9)` 加淡入，减弱动态效果时只淡）、`Motion.Fade.settle`（0.12）。
- `AppGroup/Palette.swift`、`UI/Shared/Theme/Icon.swift`：只改注释，选中的规则指向 docs/ui.md（audit.md 第 5 条）。
- `UI/Debug/StyleBoard.swift`：把三档按钮、`round`、胶囊（开、关、带箭头）、两级节头、`Chevron`、`StatusDot`、`HelpButton` 排进样板页，放在色板下面、一屏看得到。
- `apple/scripts/lint.sh`：加三条棘轮规则——系统文字样式（`.font(.caption)` 这类，Theme、Debug、Widget 除外）、`.transition(.scale`、Mac 主窗口里的 `.popover(`（设置窗口除外）；此刻还在违规的文件（文字样式 42 个、`.scale` 7 个、popover 3 个）列成规则的例外，后面的批次每清一个删一行。三条都先在不带例外时看它红过。

完成标准：`xc.sh check`；`shots.sh ios-style mac-board ios-session` 只有样板页多出新组件，其余无变化。

落地结果：`xc.sh check` 退出 0；`ios-session` 与基线逐像素相同，`mac-board` 只差随时间变的读数（时长、心电线、Cue 那一栏的滚动位置），`ios-style` 多出共享控件那一块。

## B0b 共享边界二（强，一人，等 Mac 组合并 `Theme` 后）

文件（`Typography.swift`、`Rows.swift`、`Chrome.swift` 本轮归 Mac 组）：
- 新 `UI/Shared/Theme/Spacing.swift`：`Spacing` 从 `Typography.swift` 尾部搬来，两端同名不同值，4 点格（[tokens.md](tokens.md#spacing)）。10、14、18 不另立档，按角色就近（组件内部往下 8／12／16，组与组之间往上 12／16／24），拍前后对比给你看。
- `UI/Shared/Theme/Typography.swift`：iOS 补角色（`chip`、`sectionCount`、`toolbarLabel` 等 Mac 已有的），把局部枚举里的原始字号收成角色（C14）。
- `UI/Shared/Theme/Rows.swift`：`RowMetrics.height`（Mac 32、iOS 44）。
- `UI/Shared/Theme/Chrome.swift`：`control` 读 `ControlSize.regular`。
- 新 `UI/Shared/Components/LinkRow.swift`（C5）。

完成标准：`xc.sh check`；`shots.sh ios-style mac-board ios-project mac-project` 无变化（只加名字、不改值）。

## W1：无主文件（B0a 之后并行）

| 批 | 档 | 文件（`UI/Shared/Components/` 下，另注的除外） | 改法 | 截图 |
|---|---|---|---|---|
| W1-1 胶囊 | 强 | `CaptureComposer.swift`、`NewTaskField.swift`、`PiConfigCapsules.swift`、`PiFastCapsule.swift`、`PiContextGauge.swift` | `DestinationChip` 的身子、项目胶囊、工具排各胶囊换 `chip()`，删 `ChipMetrics`、`ConfigCapsule`、`configCapsuleHeight`；`NewTaskField` 的换项目两端都给（iOS 经 `MenuButton`，W2-5、W2-8 要用）；工具排与落点同一档高（`inline`；改高前后拍给你看）；上下文明细从系统 popover 改 `bubble(isPresented:)` | ios-newsession ios-cardpicker ios-session mac-session mac-cardpicker mac-board |
| W1-2 按钮与命中 | 便 | `TaskBubbleFooter.swift`、`WaitAnswer.swift`、`PiSessionDigest.swift`、`Panel+macOS.swift`、`UnreadableLibraryView.swift`、`PreviewPages+iOS.swift`、`../Workspace/AgentLinks.swift` | "去会话""开始"换 `ControlButtonStyle(size: .compact)`，`compact: true` 换 `size: .compact`；灵感卡角的会话点命中补到 44（iOS）；回答框圆角 `Radius.nested`（`CalloutSurface` 两种底都声明 `containerShape`）；`PanelCloseButton` 换 `.round`；读不出资料库页两端都是"重试"一颗主按钮、"导出诊断"显式写次按钮（`EmptyState` 给里面的按钮默认套 primary，别处靠它，不动）；文字样式换 `Typography` | ios-task mac-task ios-session mac-session mac-cuememory ios-unreadable mac-unreadable |
| W1-3 Mac 字号 | 便 | `CardPicker.swift`、`SessionDock.swift`、`FileChip.swift`、`Deliverables.swift`、`ChatScrubber.swift`、`ChatFollow.swift`、`Composer+Attachments.swift` | 系统文字样式换 `Typography`／`Glyph`；`CardRow` 行首图标放定宽格；回到最新的点换 `StatusDot`；`.scale` 转场换 `Motion.pop` | mac-cardpicker ios-cardpicker ios-search mac-board ios-cue ios-session |
| W1-4 转场 | 便 | `Composer.swift`、`ChatScroll.swift`、`PiStateDot.swift`、`AppGroup/CueNowViews.swift` | `.scale(…)` 换 `Motion.pop`，字面 0.12 换 `Motion.Fade.settle`；斜杠面板下的 `Divider()` 删掉 | ios-session mac-session；另录 `xc.sh rec ios -- -CuePadDemo YES -CuePadScene session` 与加 `-CuePadReduceMotion YES` 的一段，逐帧看起止 |
| W1-5 选中色 | 便 | `ProjectStyle.swift` | 选中格只留 `selection` 底，去掉靛青圈；圆角 `cell / 4` 换 `Radius` 一档 | ios-projectform mac-projectform |
| W1-6 技能与规则 | 强，前置 B0b | `UI/Shared/Library/` 下 `LibrarySections.swift`、`SkillSection.swift`、`LibraryFileParts.swift`、`LibraryFileBody.swift`、`LibraryHelp.swift` | `LibraryRow` 换 `LinkRow`；行间分割线删掉；`DuplicateBar` 的系统分段换 `PaneSegment`（C3）；字号换角色；`compact: true` 换 `size: .compact` | ios-library mac-library；文件页另拍 `-CuePadScene duplicate` |

完成标准另加：每批把自己清掉的文件从 lint 棘轮的例外里删掉；W1-1 后 `rg 'ChipMetrics|ConfigCapsule|configCapsuleHeight'` 为零。

## W2：手机组、Mac 组的文件（等它们合并，或经你转派）

| 批 | 档 | 文件 | 改法 | 截图 |
|---|---|---|---|---|
| W2-1 筛选 | 强 | `UI/iOS/Search/CardSearch.swift`、`UI/macOS/Search/SearchPalette+Filters.swift`、`UI/Shared/Components/SearchFilters.swift` | `FilterChip`、`FilterCapsule` 换 `chip(on:menu:)`（关着同次按钮的安静底，iOS 的纸底细边去掉）；节头换新 `SectionHeader` | ios-search mac-search |
| W2-2 提示条 | 强 | `UI/macOS/NoticeView.swift`、`UI/iOS/NoticeBanner.swift`、`UI/Shared/Workspace/Workspace+Notice.swift`、新 `UI/Shared/Components/NoticeCapsule.swift` | 合成一个（C7）；动作换 C1；Mac 去掉 `.move`；普通 4 秒、带动作或出错 8 秒，指针悬停与键盘、读屏焦点在提示上时暂停，读屏开着时不自动收 | 用 `xc.sh rec` 录 `-CuePadNotice 已删除` 两端各一段；跑提示条相关的流程测试 |
| W2-3 点进去的行 | 强 | `UI/Shared/Cue/CueNowPanel+iOS.swift`、`UI/iOS/Home/ShelfScreen.swift`、`UI/iOS/Project/CardMorePanel.swift` | 换 `LinkRow`（44 高，面板随之变高；空与满两种都拍，核"空、少、满一个尺寸"）；`CueHostPick` 的 `.highlight` 换 secondary；记号点换 `StatusDot` | ios-cuepanel ios-sidebar ios-cue |
| W2-4 Mac 项目页 | 强 | `UI/macOS/Project/CardWall.swift`、`OlderList.swift`、`ProjectPage.swift` | 批量选择去掉靛青边与靛青对勾（只留选中底与墨色对勾，先给你看）；删除钮命中补到 28；手写的行间发丝线删掉 | mac-select mac-project |
| W2-5 手机节头与新建 | 便 | `UI/iOS/Activity/SessionList.swift`、`UI/iOS/Project/ProjectScreen.swift`、`UI/iOS/Project/CardViews.swift` | `SectionTitle`、`SectionLabel`、`OlderGroupHeader` 的标题换 `SectionHeader`；`NewTaskLine` 换 `NewTaskField`；`EmptyStateButton` 换按钮样式；"更早"行间分割线删掉（首尾圆角留着）；文字样式换角色 | ios-sessions ios-project |
| W2-6 Mac 的 Cue 页 | 强 | `UI/Shared/Cue/` 下 `CueListPanel.swift`、`CueMemoryPage.swift`、`CueSchedulePage.swift`、`ScheduleEditor.swift`、`CueHostMenu.swift`、`CueWelcome.swift`、`CueDot.swift`、`CuePage.swift`、`CueStarters.swift`；`UI/macOS/Library/LibraryToolbar.swift`、`UI/iOS/Library/LibraryScreen.swift` | 问号换 `HelpButton`（Mac 不再用系统 popover）；悬停钮命中 28；关闭换 `.round`；"好"换主按钮；`WeekdayChip` 换 `chip(on:)`；重复的系统分段换 `PaneSegment`（C3）；箭头换 `Chevron`；`CueDot` 转场换 `Motion.pop`；Mac 运行情况面板去掉 `.move` | mac-cuememory ios-cuememory mac-cuerun ios-cue mac-library ios-library |
| W2-7 Mac 设置、接入与编辑页 | 便 | `UI/macOS/Settings/SettingRow.swift`、`SettingsView.swift`、`SyncRow.swift`、`UI/Shared/Components/LastCrashRow.swift`、`UI/macOS/SetupPanel.swift`、`UI/macOS/Sidebar/Sidebar.swift`、`UI/macOS/Search/SessionResults.swift`、`UI/macOS/Trash/TrashPage.swift`、`UI/macOS/Editor/CardEditorBar.swift`、`UI/Wide/WideDrop.swift` | 删 `settingButton`，节头换 `SectionHeader`，调用处写 `ControlButtonStyle(size: .compact)`；`SetupPanel.group` 换 `rowPaper`；列表分割线删掉（菜单与系统 `Form` 里的不动）；变量从系统 popover 改 `bubble(isPresented:)`；`.title2` 换角色 | mac-settings mac-agentsetup mac-shelf mac-trash mac-search mac-editor |
| W2-8 看板的新建 | 便，前置 W2-5 | `UI/Shared/Components/TaskBoardParts.swift`、`UI/iOS/Tasks/ProgressScreen.swift`、`UI/Shared/Components/TaskMetrics.swift` | `NewTaskLine` 换 `NewTaskField` 并删它；`BoardCardMetrics.rowTitle` 换角色 | ios-progress mac-board ipad-progress |
| W2-9 收口 | 便，最后 | `UI/Shared/Theme/Controls.swift`、`UI/Shared/Components/Atoms.swift`、`UI/Shared/Components/EmptyState.swift`、`apple/scripts/lint.sh` | 删 `compact:`、`.highlight`、`EmptyStateButton`、旧 `SectionHeader` 初始化、`SectionTitle`、`SectionLabel`；lint 棘轮的例外清空 | 全部基线 |

W2-9 完成标准另加：`rg 'compact: (true|false)|\.highlight\b|EmptyStateButton|SectionTitle|SectionLabel|FilterChip|FilterCapsule|NewTaskLine|settingButton'` 在 `apple/App` 下为零。

## W3：写死的间距（B0b 之后，按目录，同目录的 W1／W2 合并后）

| 批 | 档 | 范围 |
|---|---|---|
| W3-1 | 便 | `UI/Shared/Components/` 文件名 A–L（不含 Board*、SessionRail*、`Panes.swift`、`QuotaGauge.swift`） |
| W3-2 | 便 | `UI/Shared/Components/` 文件名 M–Z（同上排除） |
| W3-3 | 便 | `UI/Shared/Library`、`Rules`、`Workspace` |
| W3-4 | 便 | `UI/iOS`（手机组合并后） |
| W3-5 | 便 | `UI/macOS`、`UI/Wide`（Mac 组合并后） |
| W3-6 | 便 | `UI/Shared/Cue`、Board*、`TaskBoardParts.swift`（Mac 组合并后） |
| W3-7 | 强，最后 | `apple/scripts/lint.sh`：禁 `padding`、`spacing:` 写数字（Theme、Debug、Widget 与 `static let` 具名常量除外）；W3-1～6 留下拿不准角色的值逐处定档、拍前后对比 |

便宜模型的做法：等于某档值的换成那一档（4→`tight`、8→`item`、12→`group`；6 只在图标与字之间换 `glyph`、2 只在光学校准处换 `hair`；页级容器的左右边换 `page`，纸、卡里的换 `inset`，浮层里的换 `panel`）；10、14、18 按角色就近：组件内部（控件、行、卡、气泡里）往下取 8／12／16，组与组之间往上取 12／16／24；拿不准是内部还是组间的，和 3、5 这类光学值一起不动，列进交付说明给 W3-7。组件自己的几何（面板宽、缩略图边长）提成组件里的具名常量，不进 `Spacing`。截图：该目录页面对应的基线全拍。

## 等合并后复查（导航与外框，本轮两组在改，这里只列）

手机组：`NarrowSidebarBar`、`NarrowRoot`、`NavProto`（三套导航的原型开关，定稿后删掉不用的）、`SessionRail*`、`Panes.swift`（iOS `PaneMetrics` 的字号是原始样式、只画图标时 38 宽与一排控件 44 不齐）、`QuotaGauge` 与额度钮、`ProgressScreen.ProgressHeader`、`ProjectScope.swift`（字面量 14／4／13、✕ 只有 32 宽、选中底手画）、`FloatingHeader.swift` 与 `FloatingHeaderLayout`、`Bars.swift`。

Mac 组：`WideRail`（`RailIcon`、`RailEarlier`）、`WideLayout`、`WideHeading`、`WideCue`、`MainWindow`、`MainColumn`、`CueColumn`／`CueTitle`、`WindowControls`（`CloseButton`、`CueListSlots`、`SyncAlertSlot`）、`PageMenu`、`BoardTopRow`、`BoardLane`／`BoardColumnHeader`、`BoardTaskCard`、`BoardCards`、`BoardWaitCard`、`SidebarQuota`、`CueHeader+iOS`、`Chrome.swift` 与 `Typography` 里栏头、列头的字号。

合并后各拍一遍 `shots.sh` 全表，对照本审计的分类（控件高、选中、箭头、命中、文字样式）复查，新问题补进对应批次或新开一批。
