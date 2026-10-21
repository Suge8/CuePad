# CuePi —— Agent 桥（macOS）

Pi、Claude Code、Codex、OpenCode 的会话都登记在同一个桥上，界面、记录器与投送执行器只认它。规则写在各类型的头注释里，从这几处读起：

- 在线会话与控制：`PiBridge`；各家怎么发现会话、怎么说话：`AgentRuntime` 的四个实现（`PiRuntime`、`ClaudeCodeRuntime`、`CodexRuntime`、`OpenCodeRuntime`）。
- 检测、安装、卸载与问模型：`AgentIntegration`、`AgentProbe`；钩子转发：`AgentHookServer` 与 `AgentHookEnvelope`。
- 会话文件与对话：`PiHistoryIndexer`、`SessionFileFormat`、`PiHistory`；状态推导：`SessionFacts`；正在说的话：`DraftParts`、`PiDraftFeed`。
- Cue 的大脑：`Brain/CueBrain.swift` 与各家实现的头注释。
- 真 Agent 用例的回放与重录：`Tests/CuePiTests/RealAgents.swift` 的头注释。
- 发话规则（在跑就先停下再以这句开新一轮；终端里的 Claude Code 在跑时说不了）：`AgentCapabilities.speakBlocked`，Pi 一侧见扩展里 `pending` 的注释。

## 协议

Pi 的桥扩展（`Extension/cuepad-bridge.ts`）与 `PiWire` 之间的线上约定。字段的语义与上报时机见扩展源码的注释；这里只列消息与字段。

- 传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，所以不用 `$TMPDIR`）。目录 0700、socket 0600；客户端还校验 socket 属主与对端 uid。扩展在 `.tmp` 名上 listen、收紧权限后才改名成 `.sock`。
- 版本：`PROTOCOL_VERSION` 只认相等，不协商。每加一条命令或改线上格式就升一号；协议号不同的会话只读出身份，状态记为 `.incompatible`。`EXTENSION_VERSION` 是扩展版本的唯一来源（`PiExtensionBundle.version` 从文件解析）。
- 结束 = 连接断开。有 `bye` 是正常退出，没有就是进程被强杀。
- 扩展只在 `tui`、`rpc` 模式启用；`print`/`json`（`pi -p`、FireCode 子代理的同进程子会话）不开 socket。

环境变量（CuePad → 扩展）：

| 变量 | 含义 |
| --- | --- |
| `CUEPAD_PI_SOCKET_DIR` | 换 socket 目录 |
| `CUEPAD_LAUNCH_TOKEN` | CuePad 开的新会话的认领标识，在 hello 的 `launchToken` 里带回；只给进程里的第一个会话 |
| `CUEPAD_HOSTED` | 后台托管：正整数，空闲多少秒后自己退出；缺省或不是正数就不是托管。扩展读出后从环境里删掉 |
| `CUEPAD_PROBE` | 探测模式：不开 socket，`session_start` 时往描述符 1 写一行 `{"cuepadProbe": {model, models}}` |

扩展 → CuePad：

| `t` | 字段 |
| --- | --- |
| `hello` | 连接后第一条：`protocol`、`extensionVersion`、`sessionId`、`sessionFile`（可空）、`pid`、`cwd`、`mode`（`tui`/`rpc`）、`tty`、`term`（终端相关环境变量）、`state`、`launchToken`、`hosted`，以及 `info` 的全部字段 |
| `state` | 只在状态切换时发：`state{kind, since, busySince, turnSince, …}`，时刻都是毫秒 |
| `info` | 只带变了的项（没出现的键不变，`null` 是新值）：`name`、`firstMessage`、`question{id, kind, text, options}`、`subagents[{name, role, state, action, startedAt, settledAt, model}]`、`model{provider, id, name, thinking, images}`、`thinking`、`models`、`context{tokens, window}`、`commands[{name, description, source, hint}]` |
| `draft` | 正在说的话：`text`（`null` 是清掉）、`since` |
| `quota` | 订阅额度的一次观测：`provider`、`windows[{seconds, used, resetsAt, model, binding}]`、`complete` |
| `ack` | 命令回应：`id`、`ok`，或 `error`（见下表）；`reload` 另带 `reloaded` |
| `bye` | 主动关闭前：`reason`（`quit`/`new`/`resume`/`fork`/`reload`） |

`state.kind`：`idle`、`thinking`、`tool`（`tool`、`tools`、`detail`）、`waiting_user`（`promptKind`、`title`）、`delegating`（自己歇下、子代理在飞）、`compacting`、`done`（`aborted`）、`error`（`error`）。

CuePad → 扩展（都带 `id`）：

| `t` | 字段 | 拒绝 |
| --- | --- | --- |
| `send` | `text`、`images[{mimeType, data}]`（base64 原图）、`deliveryId`（可选，落盘为消息上的 `cuepadDelivery`） | `empty`、`bad_request` |
| `command` | `text`：`/` 开头的整行 | `bad_request`、`unknown_command`、`missing_argument`、`unknown_model`、`no_auth` |
| `config` | `model{provider, id}`、`thinking`、`name`，至少一项 | `bad_request`、`unknown_model`、`no_auth` |
| `answer` | `promptId`、`value`（`confirm` 为布尔，`select` 为选项原文，`text` 为字符串） | `no_prompt`、`stale_prompt`、`bad_answer` |
| `abort` | — | — |
| `end` | — | — |
| `reload` | — | — |
| `quota` | — | — |

任何命令都可能以 `failed: <原因>` 拒绝。`ack` 只回给发命令的连接；多个客户端同连一个会话时各自收到全部状态，扩展不仲裁。

FireCode 经两个频道把事实交给扩展：`firecode:workers`（`{inFlight}`，在飞子代理数）与 `firecode:subagents`（`{workers}`，名册原文）。扩展不读 FireCode 的档案与会话文件。

## 接入 Agent

2026-10 按官方文档核对、实测版本：Claude Code 2.1.299、Codex 0.162.1、OpenCode 2.0.25。下面只记代码里查不到的外部事实。

终端里的会话少几样能力（`AgentCapabilities.of`），出处：

- Claude Code：CuePad 只有收件箱（只收文字）与钩子。没有图片、停止、换模型与强度、斜杠命令；钩子不带增量，也没有正在说的话。
- Codex：CuePad 不订阅终端的线程（订阅会抢走终端的审批），所以没有结束会话、上下文余量与正在说的话。
- OpenCode：服务不知道会话在哪个终端，跳不到终端。

Claude Code：

- 收件箱 socket、认证行与 `CLAUDE_CODE_MESSAGING_SOCKET`/`CLAUDE_CODE_MESSAGING_TOKEN` 在官方文档（cross-session-messaging）里；消息体格式与改名的控制消息没有，来自实测。
- 经收件箱送进去的话模型仍可能当作同伴请求：不当作对待确认的批准，偶尔会试着回传。
- AskUserQuestion 的官方作答路径是 PreToolUse；PermissionRequest 会不会为它触发，文档没写。

Codex：

- 终端会话在终端退出后由常驻服务再挂约 30 分钟（实测，文档没写），期间仍在线、能收话。
- 常驻服务把子线程推送广播给没订阅的连接，是实测行为，文档没写。
- CuePad 补的空输入那一轮，在终端里显示为一段没有提问的回答；不触发 `UserPromptSubmit`，输入框里打了一半的话不受影响（实测）。

OpenCode：

- 只认 v2。Homebrew 与官方安装脚本装的是 v2；npm 上 v2 是 `@opencode/cli`，旧包 `opencode-ai` 仍是 1.x。
- 服务登记文件 `service.json` 不在文档里；"服务活着期间有过活动就在线"是 CuePad 定的规则。
- 从没取过模型表的第一次启动：先用随包的旧表，同时联网取新表（约 1～2 秒）。这期间配置的默认模型不在旧表里时，它改用旧表第一个（它自己的终端界面也一样）。CuePad 不补，会话页显示实际用的模型。

Pi：

- 停下这一轮到真正歇下之间（通常不到一秒）会话被关掉（退出、重新载入、换会话）时，扩展里等着的话随扩展实例丢掉，`bye` 不报它们。
- 交给 Pi 的那一刻若恰好有别的东西开了一轮（Pi 在处理 `input` 与"正忙"检查之间有一次异步等待），Pi 拒收，只在它自己的界面里报错。

## 已知边界

- 会话冻结（SIGSTOP）或机器休眠造成的假死发现不了：既定取舍，不做心跳。
- 跳到终端定位不到 herdr 这类再套一层的复用器里的 pane。
- 不用 FSEvents（延迟实测数据见 `FileFollower`、`DirectoryWatcher` 的头注释）。
