# CuePi —— Pi 桥（macOS）

只依赖 Foundation/AppKit，不依赖 CueStore。三块能力，App 层各接一处：

| 能力 | 入口 | 说明 |
| --- | --- | --- |
| 实时状态与发送 | `PiBridge`（`@MainActor @Observable`） | 发现并连接所有活着的会话；`sessions` 直接给界面观察，`changes()` 给通知；`send` / `paste`；`endedSessions` 留着本次运行里已结束会话的最后快照（按 id），界面据此把指向它的发送目标显示成"已结束" |
| 安装扩展 | `PiExtensionInstaller` | 检测 Pi（≥ 0.84.4）与扩展状态，`install()`（新装/升级）、`uninstall()`；首次写入前 App 要先征得用户同意，之后的升级由 App 静默完成 |
| 历史索引 | `PiHistory.index` / `PiHistoryIndexer` | 增量读取，只给出会话列表要的摘要（id、工作目录、名字、首条用户消息（标题规则与活动会话同一处：`PiSessionName`）、最后活动）；检查点（Codable，不含正文）由 App 存进 Store，再传回来；会话目录可以在开始监听时还不存在（先装 CuePad、后装 Pi）或被删再建：盯着最近的已存在上层目录，出现后切过去并整体重扫一次 |
| 错误摘要 | `PiErrorSummary`（`PiAgentState.errorSummary`） | Pi 只上报错误原文（常是"状态码 + 提供方 JSON"）：提取状态码与提供方消息并归类（认证、额度用完——按消息内容识别、不论状态码，限流、请求被拒、服务端、网络），`title` 一句中文，`line` 再附提供方原句，`raw` 原文供悬停 |
| 跳到终端 | `PiTerminalJumper` | 用 hello 里的终端信息激活会话所在终端，尽量精确到标签页 |

`PiPaths` 是目录的唯一来源（`PI_CODING_AGENT_DIR`、socket 目录）。测试一律用临时目录，绝不碰真实 `~/.pi`。

## 协议（v1）

传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，不用 `$TMPDIR`），目录 0700、socket 0600；扩展与客户端都校验"是目录、属于当前用户、0700"，客户端还校验每个 socket 文件（属主、且只有属主可读写 0600）与连接对端的 uid。`CUEPAD_PI_SOCKET_DIR` 可覆盖目录（测试与高级用法）。

扩展 → CuePad：

| `t` | 内容 |
| --- | --- |
| `hello` | 连接后第一条：`protocol`、`extensionVersion`、`sessionId`、`sessionFile`（可空，首条消息落盘前文件不存在）、`pid`、`cwd`、`mode`（tui/rpc）、`model`、`tty`、`term{环境变量子集}`、`state`（当前状态快照）、`name`（`/name` 设的会话名，可空）、`firstMessage`（首条用户消息的前 200 个字符，可空） |
| `state` | 仅状态切换时发送：`state{kind, since(ms), …}` |
| `info` | 会话名或首条用户消息变化时（`session_info_changed`、第一条用户消息的 `message_end`）：`name`、`firstMessage` |
| `ack` | 命令回应：`id`、`ok`、`delivered`（`immediate`/`steer`/`followUp`）或 `error`（`empty`/`bad_request`/`failed: …`） |
| `bye` | 扩展主动关闭前：`reason`（`quit`/`new`/`resume`/`fork`/`reload`） |

`state.kind`：`idle`、`thinking`、`outputting`、`tool`（`tool`=最近开始的工具，`tools`=并行中的全部，可选 `detail`=该调用的一句话摘要）、`waiting_user`（`promptKind`、`title`；只覆盖扩展发起的 `ctx.ui` 弹窗）、`done`（`aborted`）、`error`（`error`）。只有 `agent_settled` 才进入 `done`/`error`。

会话显示名只有一条规则，在 `PiSessionName`（活动会话的 `PiSession.displayName` 与历史的 `PiSessionHistory.displayName` 都用它）：与 Pi 自己的会话列表一致，`/name` 设的名字 → 首条用户消息 → 工作目录名，控制字符换成空格、去掉首尾空白（单行）。`name`、`firstMessage` 是扩展 v3 加的；旧扩展没有，显示工作目录名。名字或首条消息变化时 `changes()` 给出 `.displayNameChanged`。

`detail` 是扩展 v2 加的可选字段：命令（`command`）或搜索模式（`pattern`）取首个非空行，文件类工具（`path`）取文件名，超过 120 个字符截断（含省略号）；不上报完整参数。旧扩展没有这个字段，客户端得到 `nil`，并被 `hasOutdatedExtension` 标为过期。

CuePad → 扩展（都带 `id`）：

- `{"t":"send","id","text","images":[{"mimeType","data(base64)"}],"deliverAs":"steer"|"followUp"}`：走 `sendUserMessage`，`deliverAs` 缺省 `followUp`，只在会话正忙时生效；图片发原图，Pi 自行缩放。
- `{"t":"paste","id","text"}`：走 `pasteToEditor`（在光标处粘贴，不覆盖已输入内容）；RPC 模式下退化为 `set_editor_text` 请求。

扩展只在 `tui` 与 `rpc` 模式启用；`print`/`json`（一次性的 `pi -p`）不开 socket，也就不会出现在会话列表里。

会话结束 = 连接断开（无心跳、无轮询）。有 `bye` 是正常退出；没有就是进程被强杀，此时 socket 文件会残留，由进程退出通知（kqueue）触发删除，启动扫描遇到 `ECONNREFUSED` 且文件名里的 pid 已不存在也会删。pid 还活着（可能刚 bind 还没 listen）不删。

## 多客户端

同一会话可被多个客户端（含多个 `PiBridge`）同时连接：每个客户端都先收 hello 快照，再收全部状态切换；命令走各自的连接，`ack` 只回给发送方；扩展不仲裁，命令按到达顺序交给 Pi（两个客户端同时 `send` 就是两条用户消息）。

## 版本

扩展文件里的 `EXTENSION_VERSION` 是唯一版本来源，`PiExtensionBundle.version` 由它解析。`PiExtensionInstaller.status().file` 报告已安装文件是否过期；`PiSession.hasOutdatedExtension` 报告某个运行中的会话加载的是不是旧扩展（升级文件后需重启该会话）。协议版本不同的 hello 会被拒绝并以 `.incompatible` 报告。

## 已知边界

- 只有 macOS 可用（`Process`、AppKit）：全部源文件与测试都在 `#if os(macOS)` 里，iOS 上编译为空模块。
- FSEvents 不报告"仅 bind"的 socket 创建，扩展 `chmod` 之后才可见；客户端在启动与任何目录事件时全量重扫。
- 终端跳转：tmux、Terminal.app（按 tty）、Ghostty（按工作目录，唯一匹配才聚焦）；其他终端只激活应用。herdr 等再套一层的复用器无法定位到 pane。
- 会话冻结（SIGSTOP）或机器休眠造成的假死不会被发现——既定取舍：不做心跳。
