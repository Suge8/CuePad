# CuePi —— Pi 桥（macOS）

只依赖 Foundation/AppKit，不依赖 CueStore。三块能力，App 层各接一处：

| 能力 | 入口 | 说明 |
| --- | --- | --- |
| 实时状态与发送 | `PiBridge`（`@MainActor @Observable`） | 发现并连接所有活着的会话；`sessions` 直接给界面观察，`changes()` 给通知；`send` / `paste` / `configure`（换模型与思考强度）/ `abort`（停止这一轮）；`endedSessions` 留着本次运行里已结束会话的最后快照（按 id），界面据此把指向它的发送目标显示成"已结束" |
| 安装扩展 | `PiExtensionInstaller` | 检测 Pi（≥ 0.84.4）与扩展状态，`install()`（新装/升级）；首次写入前 App 要先征得用户同意，之后的升级由 App 静默完成 |
| 历史索引 | `PiHistory.index` / `PiHistoryIndexer` | 只认 `<会话目录>/<项目目录>/*.jsonl`（与 Pi 自己的会话列表一致，FireCode 子代理的 `subagents/` 不算）；回填完成时给出全部会话文件，App 据此删掉不在其中的旧索引；增量读取，给出会话列表要的摘要（id、工作目录、名字、首条用户消息（标题规则与活动会话同一处：`PiSessionName`）、最后活动），以及这次新读到的对话（`transcript`）与问答摘要（`recap`），规则见下文"对话与摘要"；首次读（没有检查点）时只为 `transcriptWindow` 内修改过的文件（按修改时间，不读内容）解析对话，更早的只读摘要：逐行只找换行，只解码文件头、改名与第一条你的消息，最近一轮问答从文件尾往回解码到够用为止，得到的检查点与全读一样；检查点（Codable，不含正文）由 App 存进 Store，再传回来；会话目录可以在开始监听时还不存在（先装 CuePad、后装 Pi）或被删再建：盯着最近的已存在上层目录，出现后切过去并整体重扫一次 |
| 错误摘要 | `PiErrorSummary` | Pi 只上报错误原文（常是"状态码 + 提供方 JSON"）：提取状态码与提供方消息并归类（认证、额度用完——按消息内容识别、不论状态码，限流、请求被拒、服务端、网络），`title` 一句中文，`line` 再附提供方原句，`raw` 原文供悬停 |
| 后台托管 | `PiHost` | 以 RPC 模式在后台恢复已结束的会话、开新会话，连上桥后返回；空闲满时限退出；同一会话在别处打开时让出（空闲即退，在跑一轮则这一轮做完再退）；让出的进程退出后对接手的进程发 `reload`；`closeAll()` 关掉全部（关标准输入，RPC 模式读到 EOF 正常收尾）；`end(id)` 结束一个在线会话并等它退出（托管的关标准输入，终端里的走扩展的 `end` 命令） |
| 跳到终端 | `PiTerminalJumper` | 用 hello 里的终端信息激活会话所在终端，尽量精确到标签页 |

`PiPaths` 是目录的唯一来源（`PI_CODING_AGENT_DIR`、socket 目录）。测试一律用临时目录，绝不碰真实 `~/.pi`。

## 协议（v4）

传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，不用 `$TMPDIR`），目录 0700、socket 0600；扩展与客户端都校验"是目录、属于当前用户、0700"，客户端还校验每个 socket 文件（属主、且只有属主可读写 0600）与连接对端的 uid。`CUEPAD_PI_SOCKET_DIR` 可覆盖目录（测试与高级用法）。

扩展 → CuePad：

| `t` | 内容 |
| --- | --- |
| `hello` | 连接后第一条：`protocol`、`extensionVersion`、`sessionId`、`sessionFile`（可空，首条消息落盘前文件不存在）、`pid`、`cwd`、`mode`（tui/rpc）、`tty`、`term{环境变量子集}`、`state`（当前状态快照）、`launchToken`（v8 起：CuePad 开的新会话经环境变量 `CUEPAD_LAUNCH_TOKEN` 交给扩展的认领标识，只属于进程里的第一个会话，其余为 null）、`hosted`（v9 起：进程由 CuePad 在后台托管，即环境变量 `CUEPAD_HOSTED=1`），以及 `info` 的全部字段（恢复已有会话时近况从会话文件当前分支补回） |
| `state` | 仅状态切换时发送：`state{kind, since(ms), busySince(ms 或 null), …}` |
| `info` | 任一字段变化时：`name`（`/name` 设的会话名）、`firstMessage`（首条用户消息的前 200 个字符）、等你回答的弹窗 `question`、子代理 `subagents`、模型配置 `model`/`thinking`/`models`（v2 起，见下）；都可空 |
| `ack` | 命令回应：`id`、`ok`、`delivered`（`immediate`/`steer`/`followUp`）或 `error`（`empty`/`bad_request`/`failed: …`） |
| `bye` | 扩展主动关闭前：`reason`（`quit`/`new`/`resume`/`fork`/`reload`） |

`state.kind`：`idle`、`thinking`、`outputting`、`tool`（`tool`=最近开始的工具，`tools`=并行中的全部，可选 `detail`=该调用的一句话摘要）、`waiting_user`（`promptKind`、`title`；只覆盖扩展发起的 `ctx.ui` 弹窗）、`delegating`（v6 起：自己这轮已歇下，还有子代理在飞）、`done`（`aborted`）、`error`（`error`）。

计时（扩展 v6 起，旧扩展的 `since` 是细状态切换时间、没有 `busySince`）：粗状态只由 `phaseOf` 一处从 `kind` 推导——工作中（思考、输出、工具、等子代理）、等你确认、出错、空闲；`kind` 又由 `StateTracker.derive()` 从自己这轮的状态、在飞子代理数与待确认弹窗推导。`since` 是进入当前粗状态的时间，细状态之间切换不变；`busySince` 是这段连续处理开始的时间：离开空闲起（提交一条消息的 `input` 事件），到自己歇下且没有子代理在飞为止，中间等你确认也不断，空闲、出错时为 null。在飞子代理数取 FireCode 发布在 `firecode:workers` 频道的 `inFlight`（在跑、在审，或已落定但结果还没交给指挥官），与 FireCode 判断"会话进行中"同一个事实。FireCode 交回结果时，在飞数在该消息的 `input` 之后、`agent_start` 之前归零，所以从 `input` 起算这一轮，连续处理在交接处不断。只有 `agent_settled` 才进入 `done`/`error`。

会话显示名只有一条规则，在 `PiSessionName`（活动会话的 `PiSession.displayName` 与历史的 `PiSessionHistory.displayName` 都用它）：与 Pi 自己的会话列表一致，`/name` 设的名字 → 首条用户消息 → 工作目录名，控制字符换成空格、去掉首尾空白（单行）。`name`、`firstMessage` 是扩展 v3 加的；旧扩展没有，显示工作目录名。`info` 的任一字段变化时 `changes()` 给出 `.infoChanged`。

对话与摘要（v12 起只来自会话文件，扩展不再上报问答近况）：`PiHistory` 按文件里的先后读出，一行一个序号（`seq`，文件只追加，重读不变）。

- 你的消息：`role == "user"` 的消息全文（文字块换行连接）。整条文字只由一个或多个 `<名字>\n…\n</名字>` 块组成的是扩展投进来的机器消息（如 FireCode 的子代理事件、观察员、审查结果信封），不进对话、只开始一轮；块与块之间夹着真人文字就不是机器消息。CuePad 送进去的消息带着 `cuepadDelivery`（投送请求 id，见 `send`）。
- Pi 消息：一轮一条，取结束这一轮的助手消息（`stopReason` 不是 `toolUse`）的文字块；中途调工具时说的话、思考与工具输出不算，只记这一轮调了几个工具（`toolCall` 块数）与开始时间。
- 摘要：`pendingPrompt` 是你说了、这一轮还没做完的那句；一轮结束时它移进 `lastPrompt`，`lastReply` 换成这一轮的回答，问与答一起更新。机器消息触发的轮没有新的提问：回答照常更新、`lastPrompt` 沿用触发它的那件事里你说的话（如 FireCode 子代理做完后的汇报，是对你那句的答复）。上次中途退出、没做完的一轮不改问答。`lastPrompt`、`pendingPrompt` 单行（空白与控制字符折成一个空格）≤500 字符，`lastReply` 保留换行 ≤1200 字符，超出以省略号结尾。

- `question`：正在等你回答的弹窗 `{id, kind, text, options}`。`kind` 是 `confirm`/`select`/`text`（`input`）/`editor`/`custom`；`text` 是标题与说明（`confirm`）换行连接，≤500 字符；`options` 是选择框的选项原文；`id` 是这次弹窗的标识，能从 CuePad 作答的（`confirm`/`select`/`text`）才有，`editor` 没有可收起的接口、`custom` 没有文案，为 null。`ui_prompt_end` 后为 null。`ui_prompt_start` 只带标题，说明与选项靠在 `session_start` 时包装共用的 `ctx.ui` 在调用时记下；包装同时给弹窗接上一个由扩展控制的 AbortSignal（与调用方自己的合并）。

模型配置（协议 v2、扩展 v13 起；v1 的 hello 里 `model` 只是模型 id 字符串，v2 并入 info）：`model` 是当前模型 `{provider, id, name, thinking}`（`thinking` 是它支持的思考强度，规则同 pi-ai 的 `getSupportedThinkingLevels`：不支持思考的只有 `off`，`xhigh`/`max` 要模型显式声明），没选模型为 null；`thinking` 是当前强度（`pi.getThinkingLevel()`）；`models` 是可换的模型，与 Pi 的 `/model` 一致——配了范围（`--models`、`enabledModels`，即 `ctx.scopedModels`）就是范围内的，否则是已配好密钥的全部（`ctx.modelRegistry.getAvailable()`，可能几百个），当前模型总在其中。Pi 里换了模型或强度（`model_select`、`thinking_level_select` 事件）时重新上报。`PiSession.model`/`thinking`/`availableModels`，换用 `PiBridge.configure`。

子代理（扩展 v5 起）：其他扩展在同一进程里开的子会话（FireCode 用 `createAgentSession`，以 `print` 模式绑定）也会加载本扩展，但 `print` 模式不开 socket，所以不会作为独立会话出现。会话文件在父会话目录的 `subagents/` 下的子会话把名字与状态登记到进程内共享的表里，父会话的 `info.subagents`（`[{name, kind}]`，`kind` 同 `state.kind`）汇总它们；名字依次取会话名、FireCode 写在子会话系统提示里的 `<firecode_worker name="…">`、首条用户消息。`PiSession.subagents`（名字与 `activity`）给界面，同步记录里是结构化的子代理列表（`PiSubagentState`）。

`detail` 是扩展 v2 加的可选字段：命令（`command`）或搜索模式（`pattern`）取首个非空行，文件类工具（`path`）取文件名，超过 120 个字符截断（含省略号）；不上报完整参数。旧扩展没有这个字段，客户端得到 `nil`。

CuePad → 扩展（都带 `id`）：

- `{"t":"send","id","text","images":[{"mimeType","data(base64)"}],"deliverAs":"steer"|"followUp","deliveryId"}`：走 `sendUserMessage`，`deliverAs` 缺省 `followUp`，只在会话正忙时生效；图片发原图，Pi 自行缩放。`deliveryId`（v12 起，可选）是 CuePad 投送请求的 id：扩展按文字先进先出认领，在这条用户消息的 `message_end` 里写到消息对象上（`cuepadDelivery`）——扩展先收到 `message_end`、Pi 再把同一个对象写进会话文件，所以 id 随消息落盘。
- `{"t":"paste","id","text"}`：走 `pasteToEditor`（在光标处粘贴，不覆盖已输入内容）；RPC 模式下退化为 `set_editor_text` 请求。
- `{"t":"reload","id"}`（v10 起）：同一会话的另一个进程（CuePad 后台托管、让出前做完一轮）刚写过会话文件，这个进程看不到那些内容。从载入起没写过、且空闲时，经 `sendUserMessage("/cuepad-reload", {expandPromptTemplates: true})` 触发本扩展注册的命令，命令里 `switchSession(当前会话文件)` 重新载入（Pi 只在命令上下文给切换会话的能力），`ack` 带 `reloaded: true`；文件没有多出内容就什么都不做；写过了（会话已分出支线）就不动，`ctx.ui.notify` 提示一句。重新载入时扩展照常收到 `session_shutdown`/`session_start`，同一 pid 的会话先结束再出现。
- `{"t":"config","id","model":{"provider","id"},"thinking"}`（协议 v2 起）：换该会话的模型、思考强度，二者至少给一项。先 `pi.setModel`（模型取自 `ctx.modelRegistry.find`）再 `pi.setThinkingLevel`，所以强度按新模型支持的范围由 Pi 夹取；只作用于这个会话，不改 Pi 的默认设置。成功后 `info` 里的模型配置已是新值。拒绝：`bad_request`（缺项、强度不在 `off`/`minimal`/`low`/`medium`/`high`/`xhigh`/`max` 里）、`unknown_model`（模型表里没有）、`no_auth`（该提供方没配好密钥，`setModel` 返回 false）。
- `{"t":"abort","id"}`（协议 v4 起）：停止这一轮，走 Pi 的 `ctx.abort()`（与用户在 Pi 里按 Esc 同一能力）。先取消正在等的弹窗（否则这一轮卡在等你），再中止指挥官正在跑的回合，`ack` 立即回（`ok` 只表示已受理，不等歇下）；随后会话以"被中止"歇下（`state` 为 `done`、`aborted: true`），不退出，能接着说。已经空闲就什么都不做，也 `ack ok`。**只停指挥官自己这一轮**：FireCode 的子代理是独立会话，不受影响，指挥官已歇下、在等子代理（`delegating`）时没有这一轮可停，成功但状态不变；子代理落定后照常把结果投回来开始新的一轮。要连子代理一起停得在 Pi 里让指挥官 `interrupt`（FireCode 的 subagents 工具），CuePad 不做。
- `{"t":"end","id"}`（协议 v3 起）：结束会话，走用户在 Pi 里退出的同一条路（`ctx.shutdown()`）：先 `ack`，再取消正在等的弹窗、中止正在跑的一轮（否则 Pi 要等它们结束才退出），然后 TUI 恢复终端、提示怎么恢复这个会话，扩展发 `bye quit` 后连接断开。RPC 模式只在读到下一条命令或这一轮结束时检查退出请求，所以后台托管的进程不靠它，`PiHost.end` 直接关它的标准输入（RPC 读到 EOF 就收尾，不论这一轮在不在跑）。`PiBridge.end` 只发命令；要等到真的退出用 `PiHost.end`（超时抛 `PiHostError.notEnded`，多半是非托管的 RPC 进程或卡在别处）。
- `{"t":"answer","id","promptId","value"}`（v7 起）：回答正在等的弹窗。`value` 在 `confirm` 是布尔，`select` 是选项原文之一，`text` 是字符串。扩展先记下答案再 abort 自己接上的 signal：Pi 的界面随之收起（TUI 隐藏选择器与确认框，RPC 删掉待答请求并按"取消"结束），原调用的结果被换成这个答案交回发起弹窗的扩展，随后 `ui_prompt_end` 清空 `question`、状态回到工作中。拒绝：`no_prompt`（没有在等、或已经答过）、`stale_prompt`（`promptId` 不是正在等的那个）、`bad_answer`（类型不对或选项不在列表里）。

扩展只在 `tui` 与 `rpc` 模式启用；`print`/`json`（一次性的 `pi -p`）不开 socket，也就不会出现在会话列表里。

会话结束 = 连接断开（无心跳、无轮询）。有 `bye` 是正常退出；没有就是进程被强杀，此时 socket 文件会残留，由进程退出通知（kqueue）触发删除，启动扫描遇到 `ECONNREFUSED` 且文件名里的 pid 已不存在也会删。pid 还活着（可能刚 bind 还没 listen）不删。

## 多客户端

同一会话可被多个客户端（含多个 `PiBridge`）同时连接：每个客户端都先收 hello 快照，再收全部状态切换；命令走各自的连接，`ack` 只回给发送方；扩展不仲裁，命令按到达顺序交给 Pi（两个客户端同时 `send` 就是两条用户消息）。

## 版本

扩展文件里的 `EXTENSION_VERSION` 是唯一版本来源，`PiExtensionBundle.version` 由它解析。`PiExtensionInstaller.status().file` 报告已安装文件是否过期；升级文件后，已在运行的会话需重启才加载新扩展。协议版本不同的 hello 会被拒绝并以 `.incompatible` 报告。

## 已知边界

- 只有 macOS 可用（`Process`、AppKit）：全部源文件与测试都在 `#if os(macOS)` 里，iOS 上编译为空模块。
- FSEvents 不报告"仅 bind"的 socket 创建，扩展 `chmod` 之后才可见；客户端在启动与任何目录事件时全量重扫。
- 终端跳转：tmux、Terminal.app（按 tty）、Ghostty（按工作目录，唯一匹配才聚焦）；其他终端只激活应用。herdr 等再套一层的复用器无法定位到 pane。
- 会话冻结（SIGSTOP）或机器休眠造成的假死不会被发现——既定取舍：不做心跳。
