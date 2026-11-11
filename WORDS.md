# 术语

界面上的名词只用这几个：灵感、任务、子任务、正文、Agent、默认项目、置顶、归档、回收站、批注、预览、技能与规则，以及 Cue 的四个：Cue、推进中、等你、记忆。一条一个叫法或一对易混的概念；业务规则在括号里那个类型的头注释里。

- **灵感**（`Card`，`todoAt` 为空）；避免：卡片、笔记（界面上）
- **任务** vs **灵感**：同一种记录 `Card`，不互转；避免：设为任务、改回灵感（已退役）
- **子任务**（顶层任务下的任务，`subtask*`）；避免：步骤（已退役）
- **叶子** vs **任务**：叶子是没有子任务的任务
- **会话** vs **任务**：会话是 Agent 干活的地方，自己就是一等对象；任务是要交出成果的事（`SessionState`、`Card`）；避免：Agent 标签
- **正文**（任务的，`Card.rest`）；避免：提示词、草稿（界面上）
- **置顶**（`isPinned`；动作"置顶 / 取消置顶"）；避免：资料（已退役）、钉住、星标
- **默认项目**（`Project.defaultID`）；避免：未分类、收件箱（已退役；小组件的 kind `CuePadInbox` 不改）
- **项目**只是容器（可选一句 `intro`）；避免：目标卡（已退役）
- **工作区** vs **绑定的文件夹**：工作区是 CuePad 替没绑文件夹的项目建的那个文件夹（`Workspaces`），建好就是绑定的文件夹；避免：没绑文件夹开不了会话（已没有这种状态）
- **只记下** vs **对 Cue 说**：同一个输入框的两种发法（`CueComposer`）；避免：写、记一笔
- **进展**（`Route.progress`）：跨项目的看板；避免：任务页（已退役）；会话页只指打开的那一个会话
- **Agent 会话**；避免：Pi 会话（界面上）。"Pi"只指 Pi 这个产品（安装、扩展、版本、模型与 `pi` 命令）
- **项目范围**（`Workspace.projectScope`）：进展页共用的"只看哪个项目"；避免：筛选、过滤（界面上）
- **会话条**（两端通用的会话入口，`SessionRail`）；避免：底部那一排、标签栏、Tab（主导航已退役）、侧栏（宽屏）、图标条、收起（宽屏会话条说藏起）
- **抽屉**（`CueDock`）：宽屏 Cue 放不下时从窗口右缘拉出的那一栏；避免：浮出、浮层（指它时）
- **更早**（会话条上的，`EarlierPage`）：已结束的会话；项目页的"更早"是另一样（旧灵感）；避免：历史、已结束（作组名）
- **并排**（宽屏主区开着两个会话）；避免：分屏、左栏、右栏（宽屏右边一直是 Cue）
- **任务气泡**（`TaskBubble`，手机上是贴在底部的纸）；避免：浮窗、详情页
- **批注**（`ReplyNote`）vs **灵感**：批注是对回答某一段的意见，随下一句发出；避免：评论
- **预览**（`PreviewItem`）：Agent 发来要你看一眼或拍板的东西；避免：交付物、作品、截图（指它时）
- **在 Mac 上操作**（`MacRemote`，只在手机与 iPad）：用网易 UU 远程控制那台 Mac；避免：远程桌面、投屏
- **投送请求**（`DeliveryRequest`）vs **发送记录**（`sendRecords`）：请求是待执行的指令及其结果；发送记录是说过的话的快照
- **归档**（`archivedAt`）vs **回收站**（`deletedAt`）
- **正在说的话**（`LiveDraft`）vs **回答**：前者还没说完、只在内存，说完落库的才是回答；避免：草稿（那是回复框的）
- **托管** vs **历史**：在线的会话都是 CuePad 在后台开的或接着的（托管，`SessionState.hosted`，结束后也算托管过）；终端里开的只以历史出现，对它发话就由 CuePad 在后台接着它；避免：终端会话、只读会话（指在线的）
- **托管会话闲置退出** vs **结束**：前者记录留着、仍在"现在"，后者才进历史
- **拉取**（`ZonePuller`）vs **门铃**（`Relay`）：拉取是别的设备的改动到本机的唯一通路，门铃只叫这台拉一次、不带内容；避免：轮询、主动拉取、推送（指门铃时）
- **Cue**（总控 Agent，界面上显示用户起的名字 `CueProfile.name`）；避免：管家、助手、总控
- **做完**（任务完成，Cue 按证据自己定）；避免：收下、收尾、验收（界面、Cue 的系统提示与工具说明里）。看板列与项目页的列名写"已完成"，"做完"仍是 Cue 定完成的说法；经过与按钮写"完成"，"做完"只在 Cue 说的话里
- **经过**（Cue 页一轮碰到的任务与会话，一处一行，`CueTrace`）的动作词与按钮同名（`CueActivity.verb`）；Cue 自己的说法（开工、做完、对「X」说）只进它的上下文；避免：看了、对…说、停下（经过里）
- **等你** vs **拍板** vs **待回复**：等你是总称，拍板与待回复是它的两种（`CueTally`）；"等你 N"两种一起数，只说拍板的地方写明"拍板"（数字账里的"N 拍板"、Cue 页的拍板卡）；避免：待办、审批
- **推进中** vs **等你** vs **进行中**：推进中与等你的口径在 `CueTally`；进行中是任务自己的状态；避免：在管、在做（会话的）
- **待回复**（`SessionState.awaitsReply`）vs **该你了**：待回复是 Cue 值班时留给你回的会话，属于等你；该你了是 Cue 不值班时歇着的会话，不算等你；避免：待处理、等你回话
- **运行**（`AttachmentRun`）：打开着资料库的一个进程，只在代码里；避免：会话、实例（指它时）
- **持有** vs **保底**（`AttachmentFiles`）：都是附件文件旁多留的硬链接，持有管"引用还没提交"，保底管"服务器还没收下"；只在代码里
- **新消息**（Cue 页，`CueStore.cueUnread`）vs **有新回复**（会话的，`Unread`）：前者各端同步，后者只记在本机；避免：未读消息（界面上）
- **记忆**（`cueLines`）vs **置顶**（项目里的灵感）；长期生效的叫**重点**（`CueMemoryLine.pinned`），动作"标为重点""取消重点"；避免：笔记、规矩（界面上）、允许清单（已退役）、一直记着（已改名）
- **技能与规则**（`AgentLibrary`）；**规则**是 AGENTS.md 那几份（全局规则、项目规则、Pi 的系统提示）；避免：说明、指令、提示词、CLAUDE.md（界面上统称时）
- 整理只有三个动作词（`LibraryTidy`）：**一键整理**（不用你选的那几件）、**去重**（同名的技能，按钮"只留这份"）、**合并**（内容不同的规则，按钮"合并进来"）；避免：修复、清理、同步（指整理时）
- **发往 Mac**（手机上改技能与规则的纸飞机，`LibraryEdit`）；避免：保存、上传
- **定时** vs **记忆**：同存一张表（有下一次的那几条，`CueMemoryLine.remindAt`），界面上各有一页；叫醒原因写"定时到点"，动作"不再定时"；避免：提醒、计划任务、闹钟、到点（作钮名或标签）
- **班次**（`CueKeeper` 起的一个大脑进程）vs **换新**（同一个班次里开新会话）：班次与 token 数只在代码、文档与 Mac 的"运行情况"里，换新这个词不上界面；避免：交接备忘（已退役）
- **诊断**（`DiagnosticArchive`：崩溃、卡死、主线程卡住）vs **最近日志**（`RecentLogs`）：都经用户自己的 iCloud 送到他的 Mac，"导出诊断"是发给别人的那条路；避免：上传、上报、反馈（指它们时）

## 英文界面

英文界面只用这些叫法，没列的名词照 Apple 自家应用的说法。大小写只按字在界面上的位置定：导航与结构用 Title Case——页面与去处名、窗口与弹框标题（问句也是，"Forget This?"）、分段与标签页、列名、分组标题、按钮、菜单项、工具栏项、设置行的名字、空态标题；其余用句首大写——状态词与徽标（"Needs your OK"、"Not delivered"、"Not syncing"、"Running tool"）、说明、副标题、提示、帮助气泡、占位符、读屏标签与提示（同一个键也是按钮名时按按钮）、报错、横幅、通知正文、空态说明、复选框说明、斜杠命令的说明。下面的叫法作标题时 Title Case，嵌在句子与计数里小写（"3 need you"、"9 active"、"the agent session"）；Agent 不是专名，句中写 agent。一句里嵌状态词时状态词在句首（"Not syncing, can't answer now."）。同一个中文键在两种位置要不同大小写时拆键：改一处中文措辞或整句化，不在代码里改大小写。

- 灵感 Idea · 任务 Task · 子任务 Subtask · 正文 Notes · 项目 Project · 默认项目 Default Project · 置顶 Pin / Unpin / Pinned · 归档 Archive · 回收站 Trash · 批注 Comment（不叫 Note，免得和 Notes 混）· 预览 Preview · 在 Mac 上操作 Control Mac
- 进展 Progress · 看板 Board · 会话 Session · 更早 Earlier · 在旁边打开 Open Beside · Agent 会话 Agent Session · 全部项目 All Projects · 工作区 Workspace · 绑定的文件夹 Linked Folder
- Cue 的四个：Cue · 推进中 Active · 等你 Needs You · 记忆 Memory；重点 Key Points（标为重点 Key Point · 取消重点 Unmark：轻扫按钮下只放得下约 10 个字母）
- 拍板 Your Call（"等你拍板" Needs Your Call）；数字账（名牌、小组件、灵动岛与锁屏、菜单栏面板）与会话条的计数里数接小写短形：N for you（拍板）· N to reply · N active · N subagent(s) · N need(s) you
- 进行中 In Progress（任务自己的状态，不与 Active 混）· 已完成 Done（列名）· 完成 Complete（按钮）· 待回复 To Reply · 该你了 Your Turn · 新消息 New Messages · 有新回复 New Reply · 输出中 Writing…
- 经过的动作词：查看 View · 发给 Message · 新建 New · 修改 Edit · 开始 Start · 停止 Stop · 完成 Complete · 留给你 Left for You
- 技能与规则 Skills & Rules · 规则 Rules（全局规则 Global Rules · 项目规则 Project Rules）· 一键整理 Tidy Up · 去重（按钮"只留这份"）Keep This One · 合并（按钮"合并进来"）Merge In · 起步规则（按钮"填进来"）Starter Rules · Use These · 发往 Mac Send to Mac
- 定时 Schedule · 定时到点 Schedule Due · 不再定时 Stop Schedule
- 诊断 Diagnostics · 把最近日志发到 Mac Send Recent Logs to Mac · 导出诊断 Export Diagnostics
- 只记下 Just Save · 对 Cue 说 Tell Cue · 运行情况 Status · 额度 Usage · 技能 Skill · 斜杠命令 Slash Command · 思考强度 Thinking · 灵动岛与锁屏 Live Activity
