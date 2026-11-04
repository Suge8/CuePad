# 迁移分批

先由一个人落共享边界（B0a、B0b 都已落），再按文件分批迁移。同一波里的批次文件互不重叠，可以并行；W3 在同目录的 W1／W2 合并后开工。为什么要改、改成什么样见 [audit.md](audit.md) 与 [components.md](components.md)。

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

## B0b 共享边界二（强，一人）——已落

- 新 `UI/Shared/Theme/Spacing.swift`：两端同名、值按平台，4 点格（[tokens.md](tokens.md#spacing)）。Mac 原来的 `toolbarGap` 并进 `item`、`sectionTitle` 并进 `group`；`pageTop`、`replyBottom` 只 Mac；`reading` 两端都有（Mac 760、手机 640，原来 iOS 四处各写 640）。
- 一个事实只留一处：`FloatingHeaderLayout.margin`、`LibraryLayout.margin`／`bottom`、`UnreadableLibraryView`、`CuePage`、`SessionScreen`、`SettingsForm`、`CardEditorPage`、Mac 浮层离窗口边都改读 `Spacing`；`Chrome` 的 `row` 读 `RowMetrics.height`（新，Mac 32、iPad 44，原来两处同值）、`control` 读 `ControlSize.regular`、`rowLead`／`gutter`／`pad`／`cellGap`／`groupGap` 读 `Spacing`——外框仍只有 `Chrome` 一张表，数从这里来。
- `Typography` iOS 补 `sectionCount`、`toolbarTitlePaired`、`toolbarLabel`、`laneTitle`、`laneCount`；`TaskMetrics`、`BubbleMetrics`、`BoardCardMetrics.rowTitle`、`PaneMetrics`、`LibraryRowMetrics`、`BoardLane`、页顶玻璃的两行字、`SectionHeader` 的计数改读角色（同值）。
- 新 `UI/Shared/Components/LinkRow.swift`（C5），样板页有一行。
- 10、14、18 的就近规则先在几处高频件上落了一遍，看效果：玻璃胶囊左右 14→12、手机分段每段左右 14→12、会话卡片上下 14→12 与状态标到字 10→8、额度明细账号之间 14→16 与账号里 10→8、额度面板下边 18→16（窄屏侧栏与进展页那两处原来各写一遍，收成 `QuotaDetail.grownInsets`）。对比图在 `apple/.derived/polish-system/b0b-compare/`。
- lint：删掉已不存在的 `NavProto.swift` 与这次清干净的 5 个文件在文字样式棘轮里的例外。

结果：`xc.sh check` 退出 0；Mac 6 张与基线只差随时间变的读数与 Cue 那一栏的滚动位置；手机只有上面列的几处变了。

## W1（已合入 W1-1～W1-5）

| 批 | 档 | 文件（`UI/Shared/Library/` 下） | 改法 | 截图 |
|---|---|---|---|---|
| W1-6 技能与规则 | 强 | `LibrarySections.swift`、`SkillSection.swift`、`LibraryFileParts.swift`、`LibraryFileBody.swift`、`LibraryHelp.swift` | `LibraryRow` 换 `LinkRow`；行间分割线删掉；`DuplicateBar` 的系统分段换 `PaneSegment`（C3）；剩下的文字样式（`SkillSection` 6 处、`LibrarySections` 箭头）换角色与 `Chevron`；`compact: true` 换 `size: .compact` | ios-library mac-library；文件页另拍 `-CuePadScene duplicate` |

## W2（两组已合并，照下表派）

表里的文件互不重叠、可以并行，除了写明的前置。

| 批 | 档 | 前置 | 文件 | 改法 | 截图 |
|---|---|---|---|---|---|
| W2-1 筛选 | 强 | — | `UI/iOS/Search/CardSearch.swift`、`UI/macOS/Search/SearchPalette+Filters.swift`、`UI/Shared/Components/SearchFilters.swift` | `FilterChip`、`FilterCapsule` 换 `chip(on:menu:)`（关着同次按钮的安静底，iOS 的纸底细边去掉）；节头换新 `SectionHeader` | ios-search ios-sessions mac-search |
| W2-2 提示条 | 强 | — | `UI/macOS/NoticeView.swift`、`UI/iOS/NoticeBanner.swift`、`UI/Shared/Workspace/Workspace+Notice.swift`、新 `UI/Shared/Components/NoticeCapsule.swift` | 合成一个（C7）；动作换 C1；Mac 去掉 `.move`；普通 4 秒、带动作或出错 8 秒，指针悬停与键盘、读屏焦点在提示上时暂停，读屏开着时不自动收 | `xc.sh rec` 录 `-CuePadNotice 已删除` 两端各一段；跑提示条相关的流程测试 |
| W2-3 Cue 面板与点进去的行 | 强 | — | `UI/Shared/Cue/CueNowPanel.swift`（三端同一份，原 `CueNowPanel+iOS`）、`UI/iOS/Home/ShelfScreen.swift`、`UI/iOS/Project/CardMorePanel.swift` | 定时、技能与规则、在哪台 Mac 三行与书架末尾、"更多"里的行换 `LinkRow`（`CueNowPanel.line` 28 删掉，高随 `RowMetrics.height`，手机 44、Mac 32；空与满两种都拍，核"空、少、满一个尺寸"）；`CueHostPick` 的 `.highlight` 换 secondary；记号点换 `StatusDot`；面板的 `blockGap` 22、`side` 22、`top` 14、`bottom` 18 落到格上（14、18 按规则；22 不在规则里，取 24 或 `Spacing.panel` 先给你看） | ios-cuepanel ios-panel-rows ios-sidebar mac-cuememory |
| W2-4 Mac 项目页 | 强 | — | `UI/macOS/Project/CardWall.swift`、`OlderList.swift`、`ProjectPage.swift` | 批量选择去掉靛青边与靛青对勾（只留选中底与墨色对勾，先给你看）；删除钮命中补到 28；手写的行间发丝线删掉 | mac-select mac-project |
| W2-5 手机节头与新建 | 便 | — | `UI/iOS/Activity/SessionList.swift`、`UI/iOS/Project/ProjectScreen.swift`、`UI/iOS/Project/CardViews.swift` | `SectionTitle`、`SectionLabel`、`OlderGroupHeader` 的标题与 `SectionHeader(title:count:)` 换新 `SectionHeader`；`NewTaskLine` 换 `NewTaskField`；`EmptyStateButton` 换按钮样式；"更早"行间分割线删掉（首尾圆角留着）；文字样式换角色 | ios-sessions ios-project |
| W2-6 Cue 页的问号、定时与记忆 | 强 | — | `UI/Shared/Cue/` 下 `CueListPanel.swift`、`CueMemoryPage.swift`、`CueSchedulePage.swift`、`ScheduleEditor.swift`、`CueHostMenu.swift`、`CueWelcome.swift`、`CueDot.swift`、`CuePage.swift`、`CueStarters.swift`；`UI/macOS/Library/LibraryToolbar.swift`、`UI/iOS/Library/LibraryScreen.swift` | 问号换 `HelpButton`（`CueListHelp` 的系统 popover 删掉）；悬停钮命中 28；`PanelCloseButton` 换 `.round`；"好"换主按钮；`WeekdayChip` 换 `chip(on:)`；重复的系统分段换 `PaneSegment`（C3）；箭头换 `Chevron`；`CueDot` 换 `StatusDot` 的尺寸、转场换 `Motion.pop`；Mac 运行情况面板去掉 `.move`；`compact: true` 换 `size: .compact` | mac-cuememory ios-cuememory mac-cuerun ios-cue mac-library ios-library |
| W2-7 Mac 设置、接入与编辑页 | 便 | — | `UI/macOS/Settings/SettingRow.swift`、`SettingsView.swift`、`SyncRow.swift`、`UI/Shared/Components/LastCrashRow.swift`、`UI/macOS/SetupPanel.swift`、`UI/macOS/Sidebar/Sidebar.swift`、`UI/macOS/Search/SessionResults.swift`、`UI/macOS/Trash/TrashPage.swift`、`UI/macOS/Editor/CardEditorBar.swift`、`UI/Wide/WideDrop.swift` | 删 `settingButton`，调用处写 `ControlButtonStyle(size: .compact)`；节头换 `SectionHeader`；`SetupPanel.group` 换 `rowPaper`；列表分割线删掉（菜单与系统 `Form` 里的不动）；变量从系统 popover 改 `bubble(isPresented:)`；`.title2` 换角色 | mac-settings mac-agentsetup mac-shelf mac-trash mac-search mac-editor |
| W2-8 看板的新建 | 便 | W2-5 | `UI/Shared/Components/TaskBoardParts.swift`、`UI/iOS/Tasks/ProgressScreen.swift` | `NewTaskLine`（在 `ProgressScreen` 里）换 `NewTaskField` 并删掉 | ios-progress mac-board ipad-progress |
| W2-10 Mac 项目表单 | 强 | — | `UI/macOS/Sidebar/ProjectForm.swift`、`UI/Debug/DebugHooks+View.swift` | 整块是系统样式（`.roundedBorder` 输入框、系统小按钮"选择…""取消""创建"、`desk` 底）。表单只给内容，外形交给所在的 `panel`（纸底、`Radius.card`，自己不铺 `desk`）；两个输入框是同一种淡底单行框（`fill` 底、`Radius.nested`、高 `ControlSize.regular`，占位字经 `TextField(_:text:palette:)` 的 `ink3`）；"选择…"是 `ControlButtonStyle(size: .compact)`，"取消"是 `quiet`、"创建""保存"是唯一的 `primary`，同一档高。调试场景 `projectform` 现在把表单直接铺满窗口、不经 `panel`：改成经 `panel` 弹出，截图才是真实样子 | mac-projectform（新建）；另拍编辑已有项目一张 |
| W2-11 看板列头与项目范围 | 强 | — | `UI/Shared/Components/BoardLane.swift`、`UI/Shared/Components/ProjectScope.swift` | 手机与 iPad 的列头高 52、Mac 是一排控件高 36：iPad 改读 `ControlSize.regular`（44）还是留 52 给列头的大数，先拍给你看；列头"+"宽 32，补到 `ControlSize.target` 见方或说明为何例外；`ProjectScope` 手写的选中底、字面量 14／4／13 与 32 宽的 ✕ 换 `chip(on:menu:)` 与 `.round` 的清掉钮，文字样式换角色 | ios-progress ipad-progress mac-board |
| W2-9 收口 | 便 | 其余 W2 全部 | `UI/Shared/Theme/Controls.swift`、`UI/Shared/Components/Atoms.swift`、`UI/Shared/Components/EmptyState.swift`、`apple/scripts/lint.sh` | 删 `compact:`、`.highlight`、`ControlMetrics.compactHeight`、`EmptyStateButton`、旧 `SectionHeader(title:count:)`、`SectionTitle`、`SectionLabel`；lint 棘轮的例外清空 | 全部基线 |

W2-9 完成标准另加：`rg 'compact: (true|false)|kind: \.highlight|EmptyStateButton|SectionTitle|SectionLabel|FilterChip|FilterCapsule|NewTaskLine|settingButton|compactHeight'` 在 `apple/App` 下为零。

## W3：写死的间距（便，按目录；同目录的 W1-6／W2 合并后）

| 批 | 档 | 前置 | 范围 |
|---|---|---|---|
| W3-1 | 便 | W2-1、W2-5（同文件的） | `UI/Shared/Components/` 文件名 A–L（不含 Board*） |
| W3-2 | 便 | W2-2、W2-8 | `UI/Shared/Components/` 文件名 M–Z（不含 Board*） |
| W3-3 | 便 | W1-6 | `UI/Shared/Library`、`Rules`、`Workspace` |
| W3-4 | 便 | W2-1、W2-3、W2-5、W2-8 | `UI/iOS` |
| W3-5 | 便 | W2-2、W2-4、W2-7、W2-10 | `UI/macOS`、`UI/Wide` |
| W3-6 | 便 | W2-3、W2-6、W2-11 | `UI/Shared/Cue`、`UI/Shared/Components/Board*`、`TaskBoardParts.swift` |
| W3-7 | 强 | W3-1～6 | `apple/scripts/lint.sh`：禁 `padding`、`spacing:` 写数字（Theme、Debug、Widget 与 `static let` 具名常量除外）；W3-1～6 留下拿不准角色的值逐处定档、拍前后对比 |

便宜模型的做法：等于某档值的换成那一档（4→`tight`、8→`item`、12→`group`、16 在块与块之间→`block`；6 只在图标与字之间换 `glyph`、2 只在光学校准处换 `hair`；页级容器的左右边换 `page`，纸、卡里的字离边换 `inset`，浮层里的换 `panel`）；10、14、18 按角色就近：组件内部（控件、行、卡、气泡里）往下取 8／12／16，组与组之间往上取 12／16／24；拿不准是内部还是组间的，和 3、5、22 这类一起不动，列进交付说明给 W3-7。组件自己的几何（面板宽、缩略图边长）提成组件里的具名常量，不进 `Spacing`。B0b 已经落过规则的几行（`Controls` 玻璃胶囊、`PaneMetrics`、`SessionCard`、`QuotaGauge` 的明细）不再动。截图：该目录页面对应的基线全拍。

## 总验收的缺口

- **`Motion.pop` 转场没录过屏**：W1-4 只拍了静态截图，转场的起点、终点、中途反向都没看。总验收时用能触发转场的场景逐帧看，正常与减弱动态效果各一段：`xc.sh rec ios -- -CuePadDemo YES -CuePadScene style`（样板页的状态标每 3 秒在工作与歇着之间切换，触发 `PiStateDot` 的换样子），加 `-CuePadReduceMotion YES` 再录一段；Mac 与输入框里的发送钮、附件、回到最新钮各找一处会出现、消失的操作（`-CuePadClick` 或 bcu 驱动）同样录两段。逐帧看起点是 0.9 不是 0、终点到原大、减弱动态效果时只淡不缩，方法见 docs/verify.md（`ffmpeg -fps_mode vfr` 拆帧）。
- **`ios-sidebar` 的基线不稳**：同一个隔离库里上一次停在哪一段（项目或进展），这次侧栏就开在哪一段，前后两张可能不是同一段。对比时以 `ios-progress` 与 `ios-sidebar` 合起来看，或在 `shots.sh` 里给它补一个定段的启动参数。

## 合并后复查（fc370342f）

导航与外框两组合并后照原清单逐个看过，新写的文件（`Chrome`、`WideMetrics`、`BoardWidths`、`BoardColumns`、`CueNowPanel`、`EarlierScreen`、`NarrowSidebarBar`、`PiSessionRow`）也算在内：

- 已解决、不再跟：`NavProto` 删了（它在 lint 里的例外 B0b 删掉）；`PiContextGauge` 的系统 popover、`ChipMetrics`、`ConfigCapsule` 随 W1-1 没了；`ControlAnchor` 删了，气泡两端都经 `bubble(isPresented:)`；新会话入口收成一颗 `LaneAdd`。
- `Chrome` 尺寸表本身干净：B0b 让它的行高、控件高与几项间距改读 `RowMetrics`、`ControlSize`、`Spacing`，表仍是外框唯一的出处。`WideMetrics`、`BoardWidths` 的数都是组件几何（列最窄 175、空列 140、Cue 400、会话 390），留在原处、有名字、有理由，不进全局令牌。
- 页顶玻璃的两行字、手机分段与列头的字号是原始文字样式：B0b 改读角色。
- 额度明细在窄屏侧栏与进展页各写一遍内边（16／4／18）：B0b 收成一处。
- 新问题，补进上表：`CueNowPanel` 成了三端同一份，行高 28 与几个不在格上的间距（W2-3）；手机列头高 52 与一排控件 44 不齐、"+"只有 32 宽（W2-11，新开）；`ProjectScope` 仍是字面量与手画选中底（W2-11）。
- 看过没问题的：`EarlierScreen` 的"更早"格（字号走角色、纸与按压走共享件，只剩 `VStack(spacing: 1)` 归 W3-4）；`CueHeader+iOS` 的 `.buttonStyle(.plain)`（iOS 放行，名牌不要按压变淡）；`WideRail` 里的 `Divider()` 在"更早"的菜单里，是菜单分组；`CardMorePanel` 的翻页 `.move` 是手机上同级横向切换。
