# CuePi —— Pi 桥（macOS）

依赖 Foundation/AppKit 与 CueStore：Pi 会话的值类型（状态 `PiWorkState`、弹窗 `PiQuestion`、模型 `PiModelOption`、上下文 `PiContextUsage`、斜杠命令 `PiSlashCommand`、子代理 `PiSubagentState`、对话 `PiChatMessage`、摘要 `PiRecap`）只在 CueStore 定义一份，线上消息与会话文件在这里直接解码成它们，App 不再转换。三块能力，App 层各接一处：

| 能力 | 入口 | 说明 |
| --- | --- | --- |
| 实时状态与发送 | `PiBridge`（`@MainActor @Observable`） | 发现并连接所有活着的会话；`slots`（一个在线会话一格，格内的 `session` 原地更新）直接给界面观察，`session(sessionID:)` 取单个会话、`sessions` 是全部会话的快照（非界面代码与测试用），`changes()` 给通知；`send` / `command`（斜杠命令）/ `configure`（会话名、模型与思考强度）/ `abort`（停止这一轮）；会话结束只经 `changes()` 的 `.ended` 报告（带最后一刻的快照），桥不留已结束会话——已结束的会话只在同步记录里（`PiSessionState`，状态 `ended`） |
| 接入 Pi | `PiIntegration` | 检测 Pi（≥ 0.84.4），读出、写入（`install()`，新装或修复）、移除（`uninstall()`）三样：扩展 `<Pi 目录>/extensions/cuepad-bridge.ts`、skill `<Pi 目录>/skills/cuepad/SKILL.md`（与扩展同在 Pi 目录下，不写用户自己维护的 `~/.agents/skills`；正文写着链接的绝对路径，教 Agent 用 `cuepad show` 把文件发到手机，其余看 `--help`）、命令行链接 `<链接目录>/cuepad`（指向 App 的 `Contents/Helpers/cuepad`）。每样各是 `missing`/`current`/`outdated`（CuePad 写的但不是现在要的样子：旧版、链接指向移走前的 App）/`foreign`（别人的同名文件）；扩展是 CuePad 写的就算已接入。任一样是 `foreign` 时三样都不写；写到一半失败把已写的还原；移除只删 CuePad 写的。首次写入前 App 要先征得用户同意，之后的修复由 App 静默完成 |
| 历史索引 | `PiHistory.index` / `PiHistoryIndexer` | 只认 `<会话目录>/<项目目录>/*.jsonl`（与 Pi 自己的会话列表一致，FireCode 子代理的 `subagents/` 不算）；回填完成时给出全部会话文件，App 据此删掉不在其中的旧索引；增量读取，给出会话列表要的摘要（id、工作目录、名字、首条用户消息（标题规则与活动会话同一处：`PiSessionName`）、最后活动），以及这次新读到的对话（`transcript`）与问答摘要（`recap`），规则见下文"对话与摘要"；首次读（没有检查点）时只为 `transcriptWindow` 内修改过的文件（按修改时间，不读内容）解析对话，更早的只读摘要：逐行只找换行，只解码文件头、改名与第一条你的消息，最近一轮问答从文件尾往回解码到够用为止，得到的检查点与全读一样；检查点（Codable，不含正文）由 App 存进 Store，再传回来；会话目录可以在开始监听时还不存在（先装 CuePad、后装 Pi）或被删再建：盯着最近的已存在上层目录，出现后切过去并整体重扫一次 |
| 错误摘要 | `PiErrorSummary` | Pi 只上报错误原文（常是"状态码 + 提供方 JSON"）：提取状态码与提供方消息并归类（认证、额度用完——按消息内容识别、不论状态码，限流、请求被拒、服务端、网络），`title` 一句中文，`line` 再附提供方原句，`raw` 原文供悬停 |
| 后台托管 | `PiHost` | 以 RPC 模式在后台恢复已结束的会话、开新会话，连上桥后返回；空闲满时限退出（不算结束：会话记录留着、歇着，仍在"现在"，发话时再恢复）；同一会话在别处打开时让出（空闲即退，在跑一轮则这一轮做完再退）；让出的进程退出后对接手的进程发 `reload`；`closeAll()` 关掉全部（关标准输入，RPC 模式读到 EOF 正常收尾）；`end(id)` 结束一个在线会话并等它退出（托管的关标准输入，终端里的走扩展的 `end` 命令） |
| 跳到终端 | `PiTerminalJumper` | 用 hello 里的终端信息激活会话所在终端，尽量精确到标签页 |

`PiPaths` 是目录的唯一来源（`PI_CODING_AGENT_DIR`、socket 目录、命令行链接目录 `CUEPAD_BIN_DIR`）。

## 协议（v11）

传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，不用 `$TMPDIR`），目录 0700、socket 0600；扩展与客户端都校验"是目录、属于当前用户、0700"，客户端还校验每个 socket 文件（属主、且只有属主可读写 0600）与连接对端的 uid。`CUEPAD_PI_SOCKET_DIR` 可覆盖目录（测试与高级用法）。

扩展 → CuePad：

| `t` | 内容 |
| --- | --- |
| `hello` | 连接后第一条：`protocol`、`extensionVersion`、`sessionId`、`sessionFile`（可空，`--no-session` 没有；路径在第一条消息落盘前就给出，文件要等第一条消息落盘才存在——没有文件的会话结束时不进历史）、`pid`、`cwd`、`mode`（tui/rpc）、`tty`、`term{环境变量子集}`、`state`（当前状态快照）、`launchToken`（CuePad 开的新会话经环境变量 `CUEPAD_LAUNCH_TOKEN` 交给扩展的认领标识，只属于进程里的第一个会话，其余为 null）、`hosted`（进程由 CuePad 在后台托管，即环境变量 `CUEPAD_HOSTED=1`），以及 `info` 的全部字段（恢复已有会话时近况从会话文件当前分支补回） |
| `state` | 仅状态切换时发送：`state{kind, since(ms), busySince(ms 或 null), …}` |
| `info` | 变化时只带变了的那几项（没出现的键表示不变，`null` 是新值"没有"，数组项整份替换；`hello` 带全部）。可带：`name`（`/name` 设的会话名）、`firstMessage`（首条用户消息的前 200 个字符）、等你回答的弹窗 `question`、子代理名册 `subagents`、模型配置 `model`/`thinking`/`models`、上下文余量 `context` 与命令清单 `commands`（见下）；都可空 |
| `ack` | 命令回应：`id`、`ok`、`delivered`（`immediate`/`steer`/`followUp`）或 `error`（`empty`/`bad_request`/`failed: …`） |
| `bye` | 扩展主动关闭前：`reason`（`quit`/`new`/`resume`/`fork`/`reload`）、`undelivered`（受理了却没来得及交给 Pi 的话的投送请求 id，见下"压缩"） |

`state.kind`：`idle`、`thinking`、`outputting`、`tool`（`tool`=最近开始的工具，`tools`=并行中的全部，可选 `detail`=该调用的一句话摘要）、`waiting_user`（`promptKind`、`title`；只覆盖扩展发起的 `ctx.ui` 弹窗）、`delegating`（自己这轮已歇下，还有子代理在飞）、`compacting`（在压缩上下文，`session_before_compact` 到 `session_compact` / `session_compact_failed`；手动 /compact、上下文快满时自动压缩、溢出后压缩再重试都是它）、`done`（`aborted`）、`error`（`error`）。

解码时一处落成 `PiSession.state`（`PiWorkState`）与一句话说明 `PiSession.detail`：`idle` 与 `done` 都是 `settled`（`tools` 全集、`aborted`、`promptKind` 没有人读，不解码）；`tool` 的说明是"工具名 · 调用摘要"（没有摘要只有工具名），`waiting_user` 是 `title`，`error` 是 `PiErrorSummary.line`（原文留在 `PiSession.errorMessage`，悬停看）。"忙"的规则只在 `PiWorkState` 上：`isTurnRunning`（指挥官这一轮在跑，含等你确认；发送要不要问"马上说还是等它做完再说"读它）、`isWorking`（含等子代理）、`hasPendingWork`（工作中或等你确认；后台托管的 Pi 空闲计时与让出读它）。

计时：粗状态只由 `phaseOf` 一处从 `kind` 推导——工作中（思考、输出、工具、等子代理、压缩）、等你确认、出错、空闲；`kind` 又由 `StateTracker.derive()` 从自己这轮的状态、在飞子代理数与待确认弹窗推导。`since` 是进入当前粗状态的时间，细状态之间切换不变；`busySince` 是这段连续处理开始的时间：离开空闲起（提交一条消息的 `input` 事件），到自己歇下且没有子代理在飞为止，中间等你确认也不断，空闲、出错时为 null。在飞子代理数取 FireCode 发布在 `firecode:workers` 频道的 `inFlight`（在跑、在审，或已落定但结果还没交给指挥官），与 FireCode 判断"会话进行中"同一个事实。FireCode 交回结果时，在飞数在该消息的 `input` 之后、`agent_start` 之前归零，所以从 `input` 起算这一轮，连续处理在交接处不断。只有 `agent_settled` 才进入 `done`/`error`。

压缩：压缩期间 `kind` 是 `compacting`（等你确认的弹窗仍在它之前）。自动压缩发生在一轮里（回答之后、`agent_settled` 之前；溢出时压完重试这一轮），粗状态一直是工作中，计时不断，压完歇下照常是这一轮做完。手动 /compact 先停掉在跑的一轮，压缩本身发生在歇着的时候：结束、失败或被停止后会话回到压缩前的状态，`since`、`busySince` 也回到压缩开始时的值——压缩不是新的一轮，CuePad 据"起点退回"不提示"做完了"、也不算有新回复（`PiAlert.entering`）。手动压缩期间 Pi 拒收新消息（`Cannot submit a prompt while compaction is in progress`），扩展的 `sendUserMessage` 又不回报错误，所以这期间收到的 `send` 先留在扩展里、照常 `ack`（`delivered` 为排队），压缩结束后的下一轮事件循环按到达顺序交给 Pi；压完之前会话就关掉（退出、重新载入、换会话）时，`bye` 的 `undelivered` 报出它们的投送请求 id，CuePad 把这几条记为没送到（"没能送达 + 重发"，`CueStore.failAcceptedDeliveries`）。交给 Pi 派发的 `command` 没有投送请求 id、留着就报不出来，手动压缩期间直接拒绝（`compacting`）。进程被强杀没有告别，留着的话报不出来。自动压缩期间 Pi 自己排队，不经这里。

会话显示名只有一条规则，在 `PiSessionName`（活动会话的 `PiSession.displayName` 与历史的 `PiSessionHistory.displayName` 都用它）：与 Pi 自己的会话列表一致，`/name` 设的名字 → 首条用户消息 → 工作目录名，控制字符换成空格、去掉首尾空白（单行）。`info` 的任一字段变化时 `changes()` 给出 `.infoChanged`。

对话与摘要只来自会话文件（扩展不上报问答近况）：`PiHistory` 按文件里的先后读出，一行一个序号（`seq`，文件只追加，重读不变）。

- 你的消息：`role == "user"` 的消息，写成 CuePad 正文格式（`CueFormat`，与投送请求的 content 同一种）：文字块与图片块按原顺序、换行连接，文字块末尾 Pi 附给模型的图片说明行（`[Image: original …]`、`[Image converted …]`）去掉（规则只有 `PiSessionName.withoutImageNotes` 一处，会话名、对话、摘要都经它），图片块在读的时候存进附件目录（按内容哈希，已有的不重写；CuePad 发出的图片就是附件目录里那份原字节，终端里直接贴的图附件目录里原本没有）、正文里留 `![](cuepad://img/<哈希>)`；不是图片的块跳过。摘要（`recap`）、机器消息判断用去掉图片后的纯文字。整条文字只由一个或多个 `<名字>\n…\n</名字>` 块组成的是扩展投进来的机器消息（如 FireCode 的子代理事件、观察员、审查结果信封），不进对话、只开始一轮；块与块之间夹着真人文字就不是机器消息。CuePad 送进去的消息带着 `cuepadDelivery`（投送请求 id，见 `send`）。
- 系统行：会话文件里的 `compaction` 条目（压缩，终端对话里那行压缩摘要）是一条系统行，文字固定是"已压缩上下文"（不写压缩前的 token 数：这里不知道窗口多大，一个孤零零的数用户读不懂）。别的命令留下的只有设置条目（`model_change`、`thinking_level_change`、`session_info` 的会话名），终端的对话里没有它们，这里也不进对话；扩展命令自己什么都不写；`/reload` 不写；`/new`、`/clone` 是另一个会话文件。模板与 skill 展开成一条普通的用户消息（`<skill …>` 或模板正文），**没有** `cuepadDelivery`——命令请求不会被换成它，所以命令不是"你发出的话"，不在对话里挂气泡。
- Pi 消息：一轮一条，取结束这一轮的助手消息（`stopReason` 不是 `toolUse`）的文字块；中途调工具时说的话与思考不算，工具输出不进对话，只记开始时间和这一轮的工具活动（`PiChatMessage.Tools`）：调用来自助手消息里的 `toolCall` 块（名字、参数），成败来自后面的工具结果行（`isError`）。工具按名字分五类（`edit`：edit / write；`command`：bash；`read`；`search`：grep / find / ls；`other`），各类调用的次数（失败的也算在自己那一类里，清单每条自己标成败）——读、改文件按文件算，同一个文件成功地读两次、改两次只算一个；清单按发生先后至多 `PiChatMessage.Tools.itemLimit` 条、每条目标至多 `targetLimit` 个字符（路径相对会话工作目录、命令取首个非空行），改文件带从参数算出的新增、删除行数（整文件写入只有新增）；一轮结束时没等到结果的调用（被中止）按成功算。工具结果行体积大，不做 JSON 解码，只按 Pi 写出的固定键序取两头：行首的 `toolCallId`，行尾 128 字节内的 `"isError":true`；两头没找到这两个键（Pi 改了键序）就落到完整 JSON 解码，结果不变、只是慢。
- 摘要：`pendingPrompt` 是你说了、这一轮还没做完的那句；一轮结束时它移进 `lastPrompt`，`lastReply` 换成这一轮的回答，问与答一起更新。机器消息触发的轮没有新的提问：回答照常更新、`lastPrompt` 沿用触发它的那件事里你说的话（如 FireCode 子代理做完后的汇报，是对你那句的答复）。上次中途退出、没做完的一轮不改问答。`lastPrompt`、`pendingPrompt` 单行（空白与控制字符折成一个空格）≤500 字符，`lastReply` 保留换行 ≤1200 字符，超出以省略号结尾。

- `question`：正在等你回答的弹窗 `{id, kind, text, options}`。`kind` 是 `confirm`/`select`/`text`（`input`）/`editor`/`custom`；`text` 是标题与说明（`confirm`）换行连接，≤500 字符；`options` 是选择框的选项原文；`id` 是这次弹窗的标识，能从 CuePad 作答的（`confirm`/`select`/`text`）才有，`editor` 没有可收起的接口、`custom` 没有文案，为 null。`ui_prompt_end` 后为 null。`ui_prompt_start` 只带标题，说明与选项靠在 `session_start` 时包装共用的 `ctx.ui` 在调用时记下；包装同时给弹窗接上一个由扩展控制的 AbortSignal（与调用方自己的合并）。

模型配置：`model` 是当前模型 `{provider, id, name, thinking}`（`thinking` 是它支持的思考强度，规则同 pi-ai 的 `getSupportedThinkingLevels`：不支持思考的只有 `off`，`xhigh`/`max` 要模型显式声明），没选模型为 null；`thinking` 是当前强度（`pi.getThinkingLevel()`）；`models` 是可换的模型，与 Pi 的 `/model` 一致——配了范围（`--models`、`enabledModels`，即 `ctx.scopedModels`）就是范围内的，否则是已配好密钥的全部（`ctx.modelRegistry.getAvailable()`，可能几百个），当前模型总在其中。Pi 里换了模型或强度（`model_select`、`thinking_level_select` 事件）时重新上报。`PiSession.model`/`thinking`/`availableModels`，换用 `PiBridge.configure`。

上下文余量：`context` 是 `{tokens, window}`——`ctx.getContextUsage()` 的已用 token（Pi 的估算）与当前模型的上下文窗口；压缩后到下一次回答前 Pi 不知道已用多少，`tokens` 为 null（窗口仍在）；没有模型为 null。上报时机：会话载入（`session_start`，含新会话、重载、恢复）、每个回合结束（`turn_end`）、一轮彻底歇下（`agent_settled`）、压缩后（`session_compact`）、换模型（`model_select`）、切换树分支（`session_tree`），内容没变不发。

命令清单：`commands` 是 `[{name, description, source, hint}]`，名字不带斜杠（skill 是 `skill:名字`），`source` 是 `builtin` / `extension` / `prompt`（提示词模板）/ `skill`，说明截到 120 字符，`hint` 是内置命令的参数提示。内置之外的来自 `pi.getCommands()`，与载入的资源一致，只在会取到不同结果的时机取：会话载入（`session_start`，含重载，重载会重新载入扩展，等于重新上报）和每次提交消息前（`before_agent_start`；其他扩展经 `resources_discover` 追加的 skill 与提示词模板在 `session_start` 之后才载入、没有事件，这是它们之后的第一个可靠时机），不随每个回合取；内置只列能在非 TUI 下执行的：

| 内置命令 | 怎么做 |
| --- | --- |
| `/compact [说明]` | `ctx.compact`，受理后 1.5 秒内失败（没有可压缩的内容、没有模型）按拒绝报给发起方，之后的失败只提示在 Pi 里 |
| `/name <名字>` | 与 `config` 的 `name` 同一条路（`pi.setSessionName`） |
| `/model <提供方/模型>` | 与 `config` 同一条路（`pi.setModel`）；模型 id 在可选模型里唯一时可省提供方 |
| `/thinking <强度>` | `pi.setThinkingLevel` |
| `/new`、`/clone`、`/reload` | 需要命令上下文，经扩展自己注册的内部命令 `/cuepad <动作>`（`newSession` / `fork(叶子, at)` / `reload`）；这三个照常列在清单里，只有内部命令 `cuepad` 本身不列 |

做不到、不列的内置命令：`/settings`、`/scoped-models`、`/login`、`/logout`、`/resume`、`/tree`、`/fork`、`/trust`、`/llama`、`/bug`（终端里的选择器或弹窗，没有对应接口）；`/session`、`/hotkeys`、`/changelog`、`/copy`（只往终端打印或写 Mac 剪贴板，手机看不到）；`/export`、`/share`、`/import`（没有扩展接口，且涉及 Mac 上的文件与外发）；`/quit`（已有"结束会话"，托管进程要关标准输入才退得掉）。

子代理：FireCode 的子代理是同进程里的 `print` 模式子会话，不开 socket，不会作为独立会话出现。父会话的 `info.subagents` 原样转述 FireCode 发布在 `firecode:subagents` 频道的名册（整份、内容变了才发，停用发空名册；扩展不读它的档案、会话文件或 `subagents/` 目录，没装带名册的 FireCode 就没有子代理）：`[{name, role, state, action, startedAt, settledAt}]`，按启动序。`state` 是 FireCode 活动列表的分组原文——`running`、`review`（审查中）、`done`（已交回结果）、`failed`、`interrupted`（被中断）、`idle`（空闲）；`action` 是在做什么的一句话（FireCode 的界面语言，≤120 字符：当前工具、审查进度，落定后是结果首句或失败原因，空闲为空串）；`startedAt` 是本次运行的开始、`settledAt` 是落定时刻（毫秒，可空），界面自己算时长。`PiSession.subagents` 给界面，同步记录里是结构化的子代理列表（`PiSubagentState`，状态读成可扩展的 `Open<PiSubagentPhase>`）；动作文字随每次工具调用变，记录器把它和会话状态的细节一起合并写入，名册的人员、角色或状态变了才立即写。

`detail`（可空）：命令（`command`）或搜索模式（`pattern`）取首个非空行，文件类工具（`path`）取文件名，超过 120 个字符截断（含省略号）；不上报完整参数。

CuePad → 扩展（都带 `id`）：

- `{"t":"send","id","text","images":[{"mimeType","data(base64)"}],"deliverAs":"steer"|"followUp","deliveryId"}`：走 `sendUserMessage`，`deliverAs` 缺省 `followUp`，只在会话正忙时生效；图片发原图，Pi 自行缩放。`deliveryId`（可选）是 CuePad 投送请求的 id：扩展按文字先进先出认领，在这条用户消息的 `message_end` 里写到消息对象上（`cuepadDelivery`）——扩展先收到 `message_end`、Pi 再把同一个对象写进会话文件，所以 id 随消息落盘。
- `{"t":"command","id","text","deliverAs"}`：斜杠命令，`text` 是以 `/` 开头的整行（命令加参数），`deliverAs`（`steer` / `followUp`，缺省 `followUp`）只对会被展开成这一轮提示词的模板与 skill 在会话正忙时生效。内置命令（先于扩展命令匹配，与 Pi 的终端一致）由扩展调上表的接口做；其余必须是 `pi.getCommands()` 里有的名字，经 `pi.sendUserMessage(text, { deliverAs, expandPromptTemplates: true })` 交给 Pi 派发——扩展命令照常执行（会话正忙也立即执行）、模板与 skill 展开成这一轮的提示词。**不带 `expandPromptTemplates` 的 `sendUserMessage` 只把斜杠开头的话当普通文字发给模型**（`send` 就是这样），所以斜杠命令必须走 `command`。`ack` 只表示受理：扩展命令自己的输出（`ctx.ui.notify` 等）只出现在 Pi 的界面里，桥看不到；拒绝：`bad_request`（不是斜杠开头）、`compacting`（手动压缩期间交给 Pi 派发的命令，见"压缩"）、`unknown_command`（清单里没有，含纯终端交互的内置命令与内部命令）、`missing_argument`（必填参数没给）、`unknown_model` / `no_auth`（`/model`，同 `config`）、`failed: …`。
- `{"t":"reload","id"}`：同一会话的另一个进程（CuePad 后台托管、让出前做完一轮）刚写过会话文件，这个进程看不到那些内容。从载入起没写过、且空闲时，经 `sendUserMessage("/cuepad reload-session", {expandPromptTemplates: true})` 触发本扩展注册的内部命令，命令里 `switchSession(当前会话文件)` 重新载入（Pi 只在命令上下文给切换会话的能力），`ack` 带 `reloaded: true`；文件没有多出内容就什么都不做；写过了（会话已分出支线）就不动，`ctx.ui.notify` 提示一句。重新载入时扩展照常收到 `session_shutdown`/`session_start`，同一 pid 的会话先结束再出现。
- `{"t":"config","id","model":{"provider","id"},"thinking","name"}`：改该会话的设置，三者至少给一项。`name` 是会话名（去掉首尾空白后不能为空），走 Pi 设置会话名的接口 `pi.setSessionName`（同 `/name`），改后 `info` 的 `name` 随即上报；CuePad 的"重命名"走这里，不当成发给会话的话。先 `pi.setModel`（模型取自 `ctx.modelRegistry.find`）再 `pi.setThinkingLevel`，所以强度按新模型支持的范围由 Pi 夹取；只作用于这个会话，不改 Pi 的默认设置。成功后 `info` 里的模型配置已是新值。拒绝：`bad_request`（缺项、名字为空、强度不在 `off`/`minimal`/`low`/`medium`/`high`/`xhigh`/`max` 里）、`unknown_model`（模型表里没有）、`no_auth`（该提供方没配好密钥，`setModel` 返回 false）。
- `{"t":"abort","id"}`：停止这一轮，走 Pi 的 `ctx.abort()`（与用户在 Pi 里按 Esc 同一能力）。先取消正在等的弹窗（否则这一轮卡在等你），再中止指挥官正在跑的回合，`ack` 立即回（`ok` 只表示已受理，不等歇下）；随后会话以"被中止"歇下（`state` 为 `done`、`aborted: true`），不退出，能接着说。已经空闲就什么都不做，也 `ack ok`。**只停指挥官自己这一轮**：FireCode 的子代理是独立会话，不受影响，指挥官已歇下、在等子代理（`delegating`）时没有这一轮可停，成功但状态不变；子代理落定后照常把结果投回来开始新的一轮。要连子代理一起停得在 Pi 里让指挥官 `interrupt`（FireCode 的 subagents 工具），CuePad 不做。
- `{"t":"end","id"}`：结束会话，走用户在 Pi 里退出的同一条路（`ctx.shutdown()`）：先 `ack`，再取消正在等的弹窗、中止正在跑的一轮（否则 Pi 要等它们结束才退出），然后 TUI 恢复终端、提示怎么恢复这个会话，扩展发 `bye quit` 后连接断开。RPC 模式只在读到下一条命令或这一轮结束时检查退出请求，所以后台托管的进程不靠它，`PiHost.end` 直接关它的标准输入（RPC 读到 EOF 就收尾，不论这一轮在不在跑）。`PiBridge.end` 只发命令；要等到真的退出用 `PiHost.end`（超时抛 `PiHostError.notEnded`，多半是非托管的 RPC 进程或卡在别处）。
- `{"t":"answer","id","promptId","value"}`：回答正在等的弹窗。`value` 在 `confirm` 是布尔，`select` 是选项原文之一，`text` 是字符串。扩展先记下答案再 abort 自己接上的 signal：Pi 的界面随之收起（TUI 隐藏选择器与确认框，RPC 删掉待答请求并按"取消"结束），原调用的结果被换成这个答案交回发起弹窗的扩展，随后 `ui_prompt_end` 清空 `question`、状态回到工作中。拒绝：`no_prompt`（没有在等、或已经答过）、`stale_prompt`（`promptId` 不是正在等的那个）、`bad_answer`（类型不对或选项不在列表里）。

扩展只在 `tui` 与 `rpc` 模式启用；`print`/`json`（一次性的 `pi -p`）不开 socket，也就不会出现在会话列表里。

会话结束 = 连接断开（无心跳、无轮询）。有 `bye` 是正常退出；没有就是进程被强杀，此时 socket 文件会残留，由进程退出通知（kqueue）触发删除，启动扫描遇到 `ECONNREFUSED` 且文件名里的 pid 已不存在也会删。pid 还活着（可能刚 bind 还没 listen）不删。

## 多客户端

同一会话可被多个客户端（含多个 `PiBridge`）同时连接：每个客户端都先收 hello 快照，再收全部状态切换；命令走各自的连接，`ack` 只回给发送方；扩展不仲裁，命令按到达顺序交给 Pi（两个客户端同时 `send` 就是两条用户消息）。

## 版本

扩展文件里的 `EXTENSION_VERSION` 是唯一版本来源，`PiExtensionBundle.version` 由它解析。`PiIntegration.status()` 报告三样各自是否过期；升级文件后，已在运行的会话在终端里执行 /reload 才加载新扩展（Pi 重新载入扩展，同一会话、同一进程以新协议重连；已用真实 pi 验证）。**协议号只认等于**，不做版本协商（不向下兼容旧协议）：每加一条命令或改线上格式就升一号，hello 里协议号不同的会话只读出会话 id、进程、工作目录与名字（格式可能已变，其余不解析），以状态 `.incompatible` 出现在 `sessions` 里——进程在、会话没死，所以不是"已结束"，也不会被后台唤醒；之后它的消息一概不读，所有命令抛 `PiBridgeError.incompatibleExtension`（"这个会话正在终端里运行旧版扩展，在终端里执行 /reload 后再发"），进程退出（连接断开）才结束。用户升级后在终端里对这个会话执行 `/reload` 即可。`.incompatible` 变化事件只留给 hello 之后消息损坏的连接（已断开，不在 `sessions` 里）。

## 已知边界

- 只有 macOS 可用（`Process`、AppKit）：全部源文件与测试都在 `#if os(macOS)` 里，iOS 上编译为空模块。
- FSEvents 不报告"仅 bind"的 socket 创建，扩展 `chmod` 之后才可见；客户端在启动与任何目录事件时全量重扫，扫描跳过已有连接的名字。/reload 在同一路径重建 socket（名字不变），新文件的事件可能在旧连接还挂着时就被扫过，所以一条连接断开时文件还在就当场再连一次；被判为不兼容的按文件本身（inode 与创建时间）记，同一路径的新 socket 照常去连。
- 终端跳转：tmux、Terminal.app（按 tty）、Ghostty（按工作目录，唯一匹配才聚焦）；其他终端只激活应用。herdr 等再套一层的复用器无法定位到 pane。
- 会话冻结（SIGSTOP）或机器休眠造成的假死不会被发现——既定取舍：不做心跳。
- 已进 Pi 队列的话（`send` 在会话正忙时以 `followUp`/`steer` 排进去的）收不回、也改不了方式：扩展接口只有 `ctx.hasPendingMessages()`，清队列与读队列（`clearQueue`、`getFollowUpMessages`）只在 Pi 自己的会话对象与 RPC 模式的 `clear_queue` 上，扩展拿不到（Pi 1.1.0 核对）。所以 CuePad 的撤回与"改为马上说"只对还没被 Mac 领取的投送请求。
