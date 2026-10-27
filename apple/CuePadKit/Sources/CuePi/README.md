# CuePi —— Agent 桥（macOS）

Pi、Claude Code、Codex、OpenCode 的会话都登记在同一个桥上（`PiBridge`），各家怎么发现会话、怎么说话在 `AgentRuntime` 的四个实现里，与别家不同的事实（命令、目录、安装、上报通道、探测、技能位置、大脑用哪种会话）在各自 `+Facts` 文件的 `AgentFacts` 里；CuePad 掌握全部输入输出的会话（Claude Code、Codex 的托管会话与 Cue 的大脑）是 `HostedSession`。规则只写在类型的头注释里；这里只记 Pi 桥扩展的线上约定与已知边界。

## 协议

Pi 的桥扩展（`Extension/cuepad-bridge/`，装成 Pi 扩展目录下的同名目录）与 `PiWire` 之间的线上约定。字段的语义与上报时机见扩展源码的注释；这里只列消息与字段。

- 传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，所以不用 `$TMPDIR`）。目录 0700、socket 0600；客户端还校验 socket 属主与对端 uid。扩展在 `.tmp` 名上 listen、收紧权限后才改名成 `.sock`。
- 版本：`PROTOCOL_VERSION` 只认相等，不协商。每加一条命令或改了 CuePad 读的格式就升一号；协议号不同的会话只读出身份，等它换上新扩展（`PiSession.upgrading`）。只删 CuePad 不读的字段不升。
- `EXTENSION_VERSION`（入口 `index.ts` 里）是扩展版本的唯一来源（`PiExtensionBundle.version` 从文件解析）。扩展的行为变了就升：会话握手时报的版本与随包版本不同，或 CuePad 装完新版扩展后，CuePad 发 `upgrade`；扩展读磁盘上的版本，不同就歇下时重新载入。
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

`state.kind`：`idle`、`thinking`、`tool`（`tool`、`detail`）、`waiting_user`（`title`）、`delegating`（自己歇下、子代理在飞）、`compacting`、`done`、`error`（`error`）。

CuePad → 扩展（都带 `id`）：

| `t` | 字段 | 拒绝 |
| --- | --- | --- |
| `send` | `text`（文件写成一行"附件：文件名（本机路径）"，会话看不了图时图片也这样写，`AttachmentFiles.agentLine`）、`images[{mimeType, data}]`（base64 原图）、`deliveryId`（可选，落盘为消息上的 `cuepadDelivery`） | `empty`、`bad_request` |
| `command` | `text`：`/` 开头的整行 | `bad_request`、`unknown_command`、`missing_argument`、`unknown_model`、`no_auth` |
| `config` | `model{provider, id}`、`thinking`、`name`，至少一项 | `bad_request`、`unknown_model`、`no_auth` |
| `answer` | `promptId`、`value`（`confirm` 为布尔，`select` 为选项原文，`text` 为字符串） | `no_prompt`、`stale_prompt`、`bad_answer` |
| `abort` | — | — |
| `end` | — | — |
| `reload` | — | — |
| `quota` | — | — |

`{"t":"upgrade"}`：请扩展核对磁盘上的扩展版本。不带 `id`，扩展不回 `ack`，不算进 `PROTOCOL_VERSION`，协议号不同的会话也发。
**这一行的格式永远不能变**，扩展也要一直认它：要叫醒的正是协议号与 CuePad 不同的会话，它们只认得出这一行；格式一变，旧会话就再也换不上新扩展（与扩展装在 Pi 扩展目录下的路径必须稳定是同一类约束）。v38 及更早的扩展不认它（回 `bad_request`），它们自己盯着扩展目录。

任何命令都可能以 `failed: <原因>` 拒绝。`ack` 只回给发命令的连接；多个客户端同连一个会话时各自收到全部状态，扩展不仲裁。

FireCode 经两个频道把事实交给扩展：`firecode:workers`（`{inFlight}`，在飞子代理数）与 `firecode:subagents`（`{workers}`，名册原文）。扩展不读 FireCode 的档案与会话文件。

## 已知边界

- 会话冻结（SIGSTOP）或机器休眠造成的假死发现不了：既定取舍，不做心跳。
- 跳到终端定位不到 herdr 这类再套一层的复用器里的 pane。
- 不用 FSEvents（延迟实测数据见 `FileFollower`、`DirectoryWatcher` 的头注释）。
