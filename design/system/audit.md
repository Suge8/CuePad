# 设计系统审计

全 App（iOS、iPadOS、macOS）的组件与令牌收口方案，供后续分批迁移。基线 proto/polish-system 98c0ad8f7（= feat/nav-polish），这一轮只读代码与截图、没改 Swift。

- 令牌现状与写死数值的按文件计数：[tokens.md](tokens.md)
- 重复组件与合并后的接口：[components.md](components.md)
- 共享边界与迁移分批：[migration.md](migration.md)
- 截图重拍：[shots.sh](shots.sh)（名字与启动参数只在它的表里）

口径：扫 `apple/App` 的 Swift（`Sources`、`AppGroup`、`Widget`），不含 `UI/Debug` 与 `Theme` 自身，`//` 之后不算。归属按工作说明：手机组 = `UI/iOS`、`SessionRail*`、`Panes.swift`、额度钮与面板；Mac 组 = `UI/macOS`、`UI/Wide`、`UI/Shared/Cue`、看板列与卡、`Theme` 的 `Chrome`、`Typography`（含 `Spacing`）、`Rows`；其余记"无主"，这一轮就能动。

## 结论

**Block**：一条 HIGH（提示条）等 W2-2 落地；其余是 MEDIUM／LOW，靠先落一层共享边界（B0a 已落）、再按文件分批迁移收口。待拍板的几项已定，写在各条与 [components.md](components.md) 里。

颜色、圆角、投影、动画曲线已经有 lint 守着，绕开的只有个位数。缺口在三处没有令牌、也没有 lint 的地方：**间距**（Mac 只有 5 个名字，iOS 没有）、**控件高度**（十几种高散在 15 个局部尺寸枚举里）、**iOS 字号角色**（iOS 的 `Typography` 只有 21 个名字，Mac 有 36 个，缺的那些各组件拿系统文字样式自己拼）。写死的尺寸数共 1012 处、分布在 185 个文件里；重复组件约 14 组。

## 问题（按严重度）

1. **HIGH · 提示条 2.4 秒就收，撤销与出错只在这里**
   现状：`Workspace.noticeDuration = 2.4s`（`Workspace+Notice.swift:5`），不随悬停、聚焦暂停；`fail()` 的出错也走它。iOS 没有 ⌘Z，提示里的"撤销"是唯一入口。Mac `NoticeView` 与 iOS `NoticeCapsule` 是两份实现。
   改成（已定）：普通结果 4 秒；带动作（撤销、归档）或出错 8 秒；指针悬停、键盘焦点、读屏焦点在提示上时暂停计时，读屏开着时不自动收；两端合成一个提示条组件。批次 W2-2。

2. **MEDIUM · 间距没有跨端令牌**
   现状：`Spacing` 只在 Mac（`Typography.swift` 尾部，5 个名字，全 App 用 30 次）。写死的 `padding` 333 处、`spacing:` 340 处；4 点格外（不算 2、6、10 这几个光学值）114 处，10 与 14 合起来 145 处。同一个"栏边"散在 8 个具名常量里，外加 38 处字面 16。
   改成：`Spacing` 搬进 `Theme/Spacing.swift`、两端同名不同值，按"是什么"取，4 点格（[tokens.md](tokens.md#spacing)）。10、14、18 不另立档，按角色就近（已定）：组件内部往下取 8／12／16，组与组之间往上取 12／16／24。批次 B0b、W3。

3. **MEDIUM · 控件高度没有一张表**
   现状：Mac 胶囊与钮的高有 24、28、30、34、36，iOS 有 30、32、36、38、44、48、50、58；同一个输入框里，落点胶囊 24、工具排胶囊 30（Mac）。来源是 `ControlMetrics`、`ConfigCapsule`、`ChipMetrics`、`BubbleMetrics.capsule`、`PaneMetrics`、`CueListMetrics`、`LibraryRowMetrics` 等。
   改成：`ControlSize` 三档（inline、compact、regular）加一个最小命中边，两端各一组值；相邻控件同高（[components.md](components.md#c1-按钮)）。B0a 已落，调用处随 W 批迁。

4. **MEDIUM · Mac 上有 20 处 iOS 文字样式，字落到 10～11 点**
   现状：共用文件里写 `.font(.caption)`、`.footnote`、`.subheadline`、`.headline`，编进 Mac 后是 10～13 点，低于 Mac `Typography` 的 12 点下限。最显眼的是 Mac 选卡片面板的时间与摘要（`CardPicker.swift:194-213`，证据 `evidence-mac-textstyle.png`）。其余在 `SessionDock`、`UnreadableLibraryView`、`Composer+Attachments`、`FileChip`、`Deliverables`、`ChatScrubber`、`ChatFollow`、`Atoms.SectionHeader`、`TaskMetrics`、`CueHostMenu`、`CueWelcome`、`WideDrop`。全 App 另有 85 处只编进 iOS 的同类写法。
   改成：字只经 `Typography`／`Glyph`，iOS 补齐缺的角色；lint 禁系统文字样式（Widget 除外）。批次 B0b、W1-2、W1-3、W2-6、W2-7、W2-8。

5. **MEDIUM · 选中着靛青；文档自相矛盾**
   现状：docs/ui.md 规定选中只有中性淡底加墨字，但批量选择的卡描 2 点靛青边加靛青对勾（`CardWall.swift:132-140`，证据 `evidence-mac-select-indigo.png`）、置顶与"更早"行的靛青对勾（`OlderList.swift:129-138`）、项目表单的图标与颜色格描靛青圈（`ProjectStyle.swift:56-65`，证据 `evidence-picked-indigo.png`）、`ControlSurface` 的 `.highlight` 是选中底加靛青字（`Surfaces.swift:333,351`，只有 `CueNowPanel+iOS.swift:300` 用）。`Palette` 头注释、`signatureSoft`、`IconImage.Accent.lit`、`WeekdayChip` 的注释还写着"选中＝靛青"——第二个事实源。
   改成：选中一律 `selection` 加墨字；批量选择的对勾改墨色；删 `.highlight`；注释与 ui.md 对齐。批次 B0a、W1-5、W2-3、W2-4。

6. **MEDIUM · 胶囊 7 套**
   现状：筛选胶囊 iOS `FilterChip`（纸底细边、36 高）与 Mac `FilterCapsule`（淡底、28 高）关着时不是一个样子（证据 `evidence-segments-ios.png` 第二排、`evidence-mac-filters.png`）；另有 `DestinationChip`、`ConfigCapsule` 一族、`NewTaskField` 的项目胶囊、`ProjectScope`、`WeekdayChip`。
   改成（已定）：一个 `chip(on:menu:size:)`，外形就是 `ControlSurface` 的次按钮：关着同次按钮的安静底，开着是中性选中底加墨字半粗，同分段（[C2](components.md#c2-胶囊)）。批次 W1-1、W2-1、W2-6。

7. **MEDIUM · 手绘按钮绕开 ControlButtonStyle**
   现状：任务气泡的"去会话""开始"（`TaskBubbleFooter.swift:89-92,145-149`）、定时的"好"（`ScheduleEditor.swift:93-98`）、两端提示条里的动作各画一颗胶囊；`EmptyStateButton`、`settingButton` 只是给 `ControlButtonStyle` 换个名字。
   另外 `EmptyState` 给里面所有按钮套 primary：读不出资料库页在 iOS 是两颗实心主按钮，在 Mac 上主按钮落在"导出诊断"、"重试"反倒是小的次按钮（`ios-unreadable.png`、`mac-unreadable.png`）。
   改成：一个按钮样式带尺寸档（[C1](components.md#c1-按钮)），删两个薄包装；一个决策里只有一颗主按钮。批次 W1-2、W2-2、W2-6、W2-7。

8. **MEDIUM · 命中区不够**
   现状：手机 Cue 面板里定时、技能与规则、在哪台 Mac 三行只有 28 高（`CueNowPanel+iOS.swift:154,185,227`，证据 `evidence-cuepanel-rows.png`）；Mac 浮层右上的关闭与问号 26（`Panel+macOS.swift:377`、`CueListPanel.swift:83`，证据 `evidence-mac-panel-circles.png`），墙上卡的删除与记忆行的悬停钮 24（`CardWall.swift:123`、`CueListPanel.swift:153`），都低于 Mac 常用操作的 28；iOS 灵感卡角上的会话点 28（`AgentLinks.swift:47,54`）、项目范围的 ✕ 宽 32（`ProjectScope.swift:41`）。
   改成：命中边只读 `ControlSize.target`；Cue 面板三行升到 44，面板随之变高（已定，接受）。批次 W1-2、W2-3、W2-4、W2-6。

9. **MEDIUM · 分段三种长相**
   现状：`PaneSegment`（玻璃里、或自带淡底的槽里）与系统 `segmented` Picker（外观 `ThemePicker`、定时的重复、同名技能的几份 `DuplicateBar`）并存；同一屏里看得到两种选中块（证据 `evidence-segments-ios.png`）。
   改成（已定）：App 内的系统分段（定时的重复、同名技能的几份）都换 `PaneSegment`；外观在设置表单里，留系统分段（[C3](components.md#c3-分段)）。批次 W1-6、W2-6。

10. **MEDIUM · Mac 主窗口里用系统 popover**
    现状：编辑页的变量（`CardEditorBar.swift:82`）、记忆与定时的问号（`CueListPanel.swift:86`）、上下文用量的明细（`PiContextGauge.swift:54`）。docs/layout.md 已写明 Mac 不用系统 popover（另起一扇窗、首弹 85～113ms、开着时主窗口快捷键不响应）。
    改成：经 `bubble(isPresented:)`；问号说明合成一个 `HelpButton`（[C8](components.md#c8-说明气泡)）。批次 W1-1、W2-6、W2-7。

11. **MEDIUM · 节头与"点进去"的行各写各的**
    现状：节头有 `SectionTitle`、`SectionHeader`（自己写 `.headline`）、`SectionLabel` 三份，外加 7 处手写；"图标＋名字＋行尾值＋箭头"的行有 `ShelfRow`、`ShelfLine`、Cue 面板三行、`CardMorePanel.row`、`LibraryRow`，行高 28／44／48／58，箭头字号 15 种写法。
    改成：`SectionHeader(level:)` 与 `LinkRow`（[C4](components.md#c4-节头)、[C5](components.md#c5-点进去的行)）。批次 B0a、B0b、W1-3、W1-6、W2-3、W2-4、W2-5、W2-7。

12. **LOW · 转场散写**
    现状：`.scale` 从 0 起 3 处（`CueDot.swift:15`、`ChatFollow.swift:204`、`CueNowViews.swift:142`），从 0.6 起 5 处、0.9 起 1 处；字面延迟 0.12 两处（`Composer.swift:66`、`NoticeBanner.swift:19`）；Mac 上两处 `.move` 转场（`NoticeView.swift:44`、`CuePage.swift:72`），与 docs/layout.md「Mac 上开合不逐帧挪位置」冲突。
    改成：`Motion` 加 `pop` 转场与 `Fade.settle` 延迟，Mac 的两处改原地淡入。批次 B0a、W1-3、W1-4、W2-2、W2-6。

13. **LOW · 列表分割线三种写法**
    现状：非菜单的分割线 7 处：`Divider()`、`Rectangle().fill(hair)` 配手写 `.padding(.leading, 40)`（`OlderList.swift:59`、`ProjectPage.swift:120`）、iOS "更早"手拼首尾圆角加分割线（`CardViews.swift:101,126`）。
    改成（已定）：列表行之间不画分割线，靠间距与纸分组；不建 `Hairline`，这些分割线一律删。系统 `Form` 的设置页保持系统默认，菜单里的 `Divider()` 是菜单分组、不算。批次 W1-4、W1-6、W2-4、W2-5、W2-7。

14. **LOW · 同心与绕开 Radius**
    现状：回答框 `card` 圆角嵌在同样圆角的问题卡里（`WaitAnswer.swift:204`）；项目表单格子的圆角按 `cell / 4` 现算（`ProjectStyle.swift:27,42`，lint 只认数字字面量所以漏了）。
    改成：前者 `Radius.nested`（问题卡声明容器形状），后者取 `Radius` 一档。批次 W1-2、W1-5。

15. **LOW · 其余成对的重复**
    现状：新建任务一行 `NewTaskField` 与 iOS `NewTaskLine`；说明气泡 `LibraryHelp`、`CueListHelp`、`PiContextGauge` 明细；记号点 4 种尺寸（7、8、10、`CueDot.size`）；选卡片的行首图标不在定宽格里，标题起点差 2 点（证据 `evidence-mac-textstyle.png`）。
    改成：见 [components.md](components.md)。批次 W1-1、W1-3、W1-6、W2-3、W2-6、W2-8。

## 考虑过但否决

- Mac 设置窗口里的系统 popover（`SettingPopover`）：设置是单独一扇窗、系统设置也这么弹，留着。
- 会话行里靛青的状态词（运行工具、思考中、子代理工作中）：说的是"正在发生"，正是靛青的用途。
- 任务气泡里等你时"去会话"铺靛青：它是那一屏唯一的主动作，`Palette` 允许主按钮用靛青。
- 小组件与实时活动里的系统文字样式（12 处）：扩展里没有 `Typography`，按 `IslandType` 的例外处理。
- iOS 目录下 6 处 `.buttonStyle(.plain)`：lint 对 iOS 放行；其中提示条是刻意不让系统压淡，改了只增加复杂度。

## 验证

已验证：
- 计数：Python 扫描脚本按上面的口径数正则命中，数字见 [tokens.md](tokens.md)；每类抽读调用处核对过（字号、命中区、转场、选中色逐条读过源码）。
- 截图：`xc.sh shot` 三次（Mac 17、iOS 19、iPad 3）与选卡片补拍，均退出 0；之后用 `shots.sh` 按表重拍 Mac 21 张（钉成浅色）、补拍 iOS 3 张，退出 0。iOS 首批里的 `-CuePadCuePresence disabled` 没拍出启用小纸，那张删了。
- `shots.sh`：`shellcheck` 无告警，表里没有的名字退出 2。

未验证：
- 动效：没录屏，转场一条只读了代码。
- 最大辅助字号、英文界面、iPad 指针悬停、真机命中：没拍。
- 间距改 4 点格（10、14、18 按角色就近）的视觉影响：B0b 拍前后对比。

## 截图证据

全在 `apple/.derived/polish-system/`（本地、不进库）。整页基线的名字与参数见 [shots.sh](shots.sh) 的表：Mac 21 张（除 `mac-board-dark` 外钉成浅色），iOS 21 张，iPad 3 张。下面几张是裁出来的局部：

| 文件 | 看什么 |
|---|---|
| `evidence-segments-ios.png` | 同一端三种分段：系统分段（外观）、槽里的 `PaneSegment`＋纸底筛选胶囊（搜索）、玻璃里的 `PaneSegment`（技能与规则） |
| `evidence-mac-filters.png` | Mac ⌘K 的淡底筛选胶囊与范围分段（暗色） |
| `evidence-mac-textstyle.png` | Mac 选卡片面板：时间 10 点、行首图标不在定宽格里（暗色） |
| `evidence-mac-panel-circles.png` | Mac 记忆浮层右上 26 点的问号与关闭（暗色） |
| `evidence-cuepanel-rows.png` | 手机 Cue 面板 28 高的三行 |
| `evidence-picked-indigo.png` | 项目表单选中的图标与颜色描靛青圈 |
| `evidence-mac-select-indigo.png` | Mac 批量选择：卡描靛青边、置顶行与卡角的靛青对勾 |
