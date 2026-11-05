# W3-2 像素差归因

W3-2（sys-w32 的 591c667b8，共用组件 M–Z 间距）留下的 57 对前后截图（sys-w32 的 `apple/.derived/polish-system/pixel-diff.json`），逐对一句结论。判法：差异像素叠在改后图上看落在哪；落在 W3-2 改过的组件上算本批间距，落在会随时间、动画、截图时机变的地方算噪声。可疑的两对在 sys-w37 连拍两次核对过。

| 截图 | 结论 |
|---|---|
| ios-atlas-slash | 本批间距（斜杠面板左右 18→16）；另有气泡旁纸飞机的帧 |
| ios-cardpicker | 时间读数（行尾「N 分钟前」） |
| ios-cue-dark | 时间读数（拍板卡「已等 N 分钟」） |
| ios-cue | 时间读数（经过各行的时刻按启动时刻倒推，前后相隔 11 分钟，字宽一变整行重排） |
| ios-cuememory | 玻璃渲染噪声（页顶两颗圆钮的玻璃折射，内容没动） |
| ios-cuepanel | 时间读数（刚记下两条的「N 分钟前」） |
| ios-editor | 时间读数（页顶「改于 N 分钟前」） |
| ios-library | 无差异 |
| ios-newsession | 本批间距（看板卡内边 14→12、上下 18→16，背后的看板） |
| ios-notes | 本批间距（回复框里的批注行） |
| ios-panel-rows | 时间读数（刚记下的「N 分钟前」） |
| ios-preview-reply | 本批间距（全屏预览底部回复栏左边 18→16） |
| ios-progress | 时间读数（卡下沿时长）与心电线的帧 |
| ios-project | 无差异 |
| ios-projectform | 截图噪声（灵动岛一张有一张没有） |
| ios-quota | 本批间距（额度明细 10→8）；另有背后看板的时长 |
| ios-search | 时间读数（行尾时长） |
| ios-session-dark | 本批间距（回复框锁住时那一行左边 18→16） |
| ios-session | 本批间距（同上） |
| ios-sessions | 时间读数（行尾时长） |
| ios-settings | 无差异 |
| ios-sidebar | 截图噪声（侧栏停在上次那一段，前后不是同一段，见 migration.md「总验收的缺口」） |
| ios-slash | 玻璃渲染噪声（页顶标题玻璃，237 像素） |
| ios-style | 无差异 |
| ios-task | 本批间距（任务气泡内边 14→12、行条 10→8、编辑器上下 10→8） |
| ios-trash | 时间读数（「删于 N 分钟前」） |
| ios-unreadable | 截图噪声（灵动岛） |
| ipad-progress | 时间读数（卡下沿时长、额度读数）与心电线的帧 |
| ipad-session | 本批间距（回复框锁住时那一行） |
| ipad-settings | 心电线的帧（会话条格里的线，循环动效截在不同时刻） |
| ipad-slash | 心电线的帧（同上） |
| mac-agentsetup | 本批间距（背后项目页任务行圈与标题 10→8）；另有 Cue 栏滚动位置、心电线 |
| mac-atlas-slash | 本批间距（斜杠面板）；另有心电线、纸飞机的帧 |
| mac-board-dark | 本批间距（看板卡上下 14→12，推进中、等你两列）；另有时长与 Cue 栏 |
| mac-board | 本批间距（同上）；另有时长与 Cue 栏 |
| mac-cardpicker | 时间读数（选卡片各行「N 分钟前」）与 Cue 栏滚动位置 |
| mac-context | 本批间距（上下文明细内边与胶囊 10→8）；另有 Cue 栏 |
| mac-cuebar | 无差异 |
| mac-cuememory | 本批间距（背后任务行）；另有 Cue 栏 |
| mac-cuerun | 本批间距（背后任务行）；另有心电线 |
| mac-editor | Cue 栏滚动位置与心电线；编辑页本身没动 |
| mac-library | Cue 栏滚动位置与心电线；技能与规则页本身没动 |
| mac-menubar | 时间读数（在做那几行的时长） |
| mac-notes | 本批间距（回复框里的批注行）；另有 Cue 栏 |
| mac-preview-reply | 本批间距（全屏预览底部回复栏左边 18→16）；另有 Cue 栏 |
| mac-project | 本批间距（任务行圈与标题 10→8）；另有心电线 |
| mac-projectform | 本批间距（背后任务行）；另有 Cue 栏 |
| mac-search | 本批间距（背后任务行）与时间读数（结果行） |
| mac-select | 本批间距（任务行） |
| mac-session | 本批间距（回复框锁住时那一行）；另有 Cue 栏 |
| mac-settings-agents | 可疑，已核对：Agent 行副题的深浅（检测还没回来时整行淡一档，截图时机），不是间距；sys-w37 连拍两次核对 |
| mac-settings | 可疑，已核对：整页低幅差异是设置窗口的材质透出桌面，排版没动；sys-w37 连拍两次核对 |
| mac-shelf | Cue 栏滚动位置与心电线；项目列表本身没动 |
| mac-slash | 心电线的帧与 Cue 栏；这张里斜杠面板没弹出来（输入框只有「/re」、会话还没说过话），面板的改动不在画面里 |
| mac-task | 本批间距（任务气泡内边、行条 10→8）与背后任务行 |
| mac-trash | 时间读数（「删于 N 分钟前」）与 Cue 栏 |
| mac-unreadable | 本批间距（读不出资料库那张卡里详情块的内边 14→12，卡变矮后整张重新居中） |

合计：本批间距 25 对，时间读数、动画帧与截图噪声 27 对，无差异 5 对。没有落在 W3-2 范围外、又说不出来源的差异。
