# CuePi —— Agent 桥（macOS）

Pi、Claude Code、Codex、OpenCode、Grok Build、dsh 的会话都登记在同一个桥上（`PiBridge`），各家怎么发现会话、怎么说话在 `AgentRuntime` 的各家实现里，与别家不同的事实（命令、目录、安装、上报通道、探测、技能位置、大脑用哪种会话）在各自 `+Facts` 文件的 `AgentFacts` 里；CuePad 掌握全部输入输出的会话（Claude Code、Codex、Grok Build、dsh 的托管会话与 Cue 的大脑）是 `HostedSession`。说 ACP（Agent Client Protocol）的 Agent 共用一个驱动（`ACP/`：`ACPSession` 托管会话与大脑是同一份，托管会话的起法与登记是 `ACPHost`），各家的扩展方法只经 `ACPDialect` 的扩展点接进来，各家的文件在自己的目录里（`Grok/`、`Dsh/`）。规则只写在类型的头注释里；这里只记 Pi 桥扩展的线上约定与已知边界。

## 支持范围

Pi 最低 1.4.0；生命周期与重试在未改动的官方 npm 1.4.0 原包上验证（Node 26.13.0、Bun 1.4.4）。不需要 fork 或修改用户配置。
RPC 扩展对自身发 SIGTERM 是这版运行时的已验证收尾路径，不是公开 SDK 对任意未来版本的保证。

## 协议

Pi 的桥扩展（`Extension/cuepad-bridge/`，装成 Pi 扩展目录下的同名目录）与 `PiWire` 之间的线上约定。字段的语义与上报时机见扩展源码的注释；这里只列消息与字段。

- 传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，所以不用 `$TMPDIR`）。目录 0700、socket 0600；客户端还校验 socket 属主与对端 uid。扩展在 `.tmp` 名上 listen、收紧权限后才改名成 `.sock`。
- 版本：`EXTENSION_VERSION`（入口 `index.ts` 里）是唯一的版本号（`PiExtensionBundle.version` 从文件解析），扩展改了就升。会话握手时报的版本与随包版本不同，或 CuePad 装完新版扩展后，CuePad 发 `upgrade`；扩展读磁盘上的版本，不同就等会话连同子代理都歇下时重新载入（重新载入会中断进程内子代理在飞的回合，所以可能等几个小时）。
- 兼容：CuePad 读得懂从 `PiWire.oldestExtension` 到随包版本的扩展，等换新扩展的这段照常收发。只加命令、加 CuePad 可以没有的字段不提它，旧扩展不认的命令回 `bad_request`；改了 CuePad 读的格式、已有命令的含义，或 CuePad 要靠新字段才对时提到那一版。区间外的会话只读出身份、不发命令，等它换上新扩展（`PiSession.upgrading`）。
- 连接断开只表示下线。显式结束要等 `bye quit` 后断开；重载、切换与未告别断线不报结束成功。同一 Pi 会话的全部已知承载进程都收尾后才完成。
- 扩展只在 `tui`、`rpc` 模式启用；`print`/`json`（`pi -p`、FireCode 子代理的同进程子会话）不开 socket。

环境变量（CuePad → 扩展）：

| 变量 | 含义 |
| --- | --- |
| `CUEPAD_PI_SOCKET_DIR` | 换 socket 目录 |
| `CUEPAD_LAUNCH_TOKEN` | CuePad 开的新会话的认领标识，在 hello 的 `launchToken` 里带回；只给进程里的第一个会话 |
| `CUEPAD_HOSTED` | 后台托管：正整数，空闲多少秒后自己退出；缺省或不是正数就不是托管。扩展读出后从环境里删掉 |
| `CUEPAD_PROBE` | 探测模式：不开 socket，`session_start` 时往描述符 1 写一行 `{"cuepadProbe": {model, models}}` |

环境变量（扩展 → 命令）：`CUEPAD_SESSION_ID`，扩展设在所在进程的环境里，值是它服务的会话；同进程的子代理会话与命令都继承它，`cuepad show` 先认它（`AgentKind.watchedSessionVariable`）。

扩展 → CuePad：

| `t` | 字段 |
| --- | --- |
| `hello` | 连接后第一条：`extensionVersion`、`sessionId`、`sessionFile`（可空）、`pid`、`cwd`、`mode`（`tui`/`rpc`）、`tty`、`term`（终端相关环境变量）、`state`、`launchToken`、`hosted`，以及 `info` 的全部字段 |
| `state` | 只在状态切换时发：`state{kind, since, busySince, turnSince, …}`，时刻都是毫秒 |
| `info` | 只带变了的项（没出现的键不变，`null` 是新值）：`name`、`firstMessage`、`question{id, kind, text, options}`、`subagents[{name, role, state, action, startedAt, settledAt, model}]`、`model{provider, id, name, thinking, images, account{kind, scope, source?, route?, name?}, proven?{account, at}}`、`thinking`、`models`、`context{tokens, window}`、`commands[{name, description, source, hint}]` |
| `draft` | 正在说的话：`text`（`null` 是清掉）、`since` |
| `quota` | 授权的额度能力与结果：`provider`（模型在 Pi 里的提供方；网关清单 `accounts` 里是上游）、`account{kind, scope, source?, route?, name?}`、`status`（`observed`/`unobserved`/`unsupported`/`failed`）、`windows[{seconds, used, resetsAt, model, binding}]`、`complete`、`observedAt?`（原观测的 Unix 秒）、`activeScopes?`（此来源成功返回的账号分区）、`accounts?`（同一次网关清单中的各账号报告）、`details?{kind, plan?, balance?, values[]}`、`requestedAt?`（排序时刻的 Unix 秒：主动查询取请求开始，回复带回的取收到回复） |
| `ack` | 命令回应：`id`、`ok`，或 `error`（见下表）；`reload` 另带 `reloaded` |
| `bye` | 主动关闭前：`reason`（`quit`/`new`/`resume`/`fork`/`reload`） |

`account.kind` 来自宿主认证事实（`oauth`/`apiKey`）；`scope` 是请求授权的不可逆分区，不传凭据。原生订阅只为当前模型的提供方解析授权；其他提供方的原生 OAuth 只报种类与 `scope=null`，主动查额度时再解析。未解析的授权（`scope=null`）是这个提供方的一条，不关联任何账号的数值：主动查询时解析失败报带 `requestedAt` 的 `failed`，其他提供方还没查的报能力；能力声明不带排序时刻，不报失败；解析失败不归到之前的账号。CuePad 让它与同一提供方证明了身份的结果按同一个时刻排先后：已有证明时不记"还没查"，失败只在没有不早于它的证明时记，证明不早于它的结果到来时移除它。`proven` 是这个会话最近一次证明的授权与开始解析的时刻（Unix 秒，解析失败不抹掉）：CuePad 只据此决定保留哪些记录，不据此关联额度；一条记录只在可能拥有它的每个模型都证明了别的授权、且证明不早于这条记录最近的结果时移除，没有证明的模型是未知，什么都不移除。实际地址与认证经宿主 `getApiKeyAndHeaders(model)` 取得，自定义地址不调用原生订阅接口。回复流里的额度只在回合前已报告的原生 OAuth 分区与收到回复后重新解析的一致时归到它，不一致就丢掉这次并重报模型身份。

自定义来源从模型实际 baseUrl 下的 `magpie/quotas` 查询，复用请求认证与配置头，不另存网关地址或密钥。404/405/501 表示不支持，其余请求失败明确报失败。网关账号以 `source`（实际地址与认证的不可逆分区）、完整上游 `route` 与 user 分开；可选 `name` 只作显示。网关来源一级按来源一条记录，几个提供方指向同一网关时同在一条上排先后；成功清单的 `accounts` 用清单的 `requestedAt`，与 `activeScopes` 同事务更新，只移除该来源已经撤销的账号；损坏清单不部分写入。主动查询的成功、失败与不支持结果和回复带回的观测都带 `requestedAt`，CuePad 按账号或网关来源只收不早于已收下的，先结束的操作不会盖过后开始的。原生查询的 `observedAt` 取响应解析完成时刻，回复取收到时刻，网关账号仍保留自己的 `readAt`。在线会话共同保留仍有效的来源；单个旧授权失败不阻止其他来源刷新。

额度面板打开、回前台与连接来源变化时读取账号清单，同时来的查询合并；已有账号的观测新鲜不能阻止发现新账号。手机通过原 `quota` 投送请求询问每台来源 Mac，不增加轮询，也不只选择最近写记录的 Mac。

magpie 的 `balance` 字符串原样显示，金额与 credits 不作百分比；`plan` 保留提供方名称。窗口仅在名字明确是数字加 `hour(s)`、`day(s)`、`week(s)` 且有百分比和重置时间时计算匀速线与额度环；其他计量、`display` 纯文字、`unlimited` 与数值 `balance` 只显示读数，不推测周期。`readAt` 原样作为账号的 `observedAt`；没有它就是未知，`asOf` 与取缓存的时刻不代替它。每个账号标原观测时间，陈旧与失败明确标出，零余额照常显示。

magpie v0.1.2190 的 [公开结构](https://github.com/yetone/magpie/blob/v0.1.2190/internal/provider/quotas.go) 与[网关接口](https://github.com/yetone/magpie/blob/v0.1.2190/internal/gateway/gateway.go)已核对。GET `/v1/magpie/quotas` 不保证更新 Claude 观测：Claude Code 回答或 `/usage` 才更新。官方另有 POST `/v1/magpie/quotas/refresh`，可能在账号目录运行 CLI；CuePad 不自动调用它，不复制上游登录或以反复 GET 冒充实时刷新。

账号窗口只在模型 id 明确指定完整上游、且该上游只有一个账号时关联；嵌套 provider 取最长前缀。自动池与多个账号不显示模型额度环，菜单明确路由账号未知，账号列表分别显示额度；`last` 不用于预测路由。单网关不显示来源标签，多来源时才按已有 Mac 名称与同机网关编号区分，不把地址拼进账号名。

ChatGPT plan（`openai` OAuth）当前没有公开额度查询能力，报 `unsupported`，管理入口为 https://chatgpt.com/settings/usage；不调用 Codex 用量接口。`ack.ok` 只代表命令已处理，不代表获得数值观测。过重置时刻无新观测算过期，不推算为满额。

普通生成 `stopReason=length` 保留 `draft`，终态走现有 `error`（`max_output_tokens`）；历史保留部分文字及未完成记录。

`state.kind`：`idle`、`thinking`、`tool`（`tool`、`detail`）、`waiting_user`（`title`）、`delegating`（自己歇下、子代理在飞）、`compacting`、`done`、`error`（`error`）。

CuePad → 扩展（都带 `id`）：

| `t` | 字段 | 拒绝 |
| --- | --- | --- |
| `send` | `text`（文件写成一行"附件：文件名（本机路径）"，会话看不了图时图片也这样写，`AttachmentFiles.agentLine`）、`images[{mimeType, data}]`（base64 原图）、`deliveryId`（可选，落盘为消息上的 `cuepadDelivery`）、`cueTurn{deliveryId}`（可选，见下） | `empty`、`bad_request`、`unconfirmed_turn`、`user_turn` |
| `command` | `text`：`/` 开头的整行 | `bad_request`、`unknown_command`、`missing_argument`、`unknown_model`、`no_auth` |
| `config` | `model{provider, id}`、`thinking`、`name`，至少一项 | `bad_request`、`unknown_model`、`no_auth` |
| `answer` | `promptId`、`value`（`confirm` 为布尔，`select` 为选项原文，`text` 为字符串） | `no_prompt`、`stale_prompt`、`bad_answer` |
| `abort` | — | — |
| `retry` | — | `nothing_to_retry` |
| `end` | — | — |
| `reload` | — | — |
| `quota` | — | — |

`{"t":"upgrade"}`：请扩展核对磁盘上的扩展版本。不带 `id`，扩展不回 `ack`，CuePad 读不懂的扩展也发。
**这一行的格式永远不能变**，扩展也要一直认它：要叫醒的也有 CuePad 读不懂的旧扩展，它们只认得出这一行（与 hello 里身份那几项、`bye`）；格式一变，旧会话就再也换不上新扩展（与扩展装在 Pi 扩展目录下的路径必须稳定是同一类约束）。v38 及更早的扩展不认它（回 `bad_request`），它们自己盯着扩展目录。

`send` 缺省是人类发送；`cueTurn` 出现即是 Cue 的发送策略，空对象没有接管忙轮的许可。桥在实际派发前按 Store 权威的 Unix 毫秒表示核对当前 peer 的轮次时间与 `PiSendPolicy.cue`；扩展在停止、提交与推进排队消息前，以 SDK 的忙闲事实及当前投影最后一条用户消息的 `cuepadDelivery` 核对许可标识。SDK 有待处理消息时，即使 `isIdle` 为真也不放行 Cue：公开接口没有队列来源证据，不能用当前轮的许可抢先。缺证据回 `unconfirmed_turn`，标识不同回 `user_turn`，都未提交这句话、也不打断原轮。不按会话名字、目录或是否托管过滤辅助 RPC。

`send` / `retry` 交出前通过公开 modelRegistry 核对当前模型及授权；明确缺授权回 `no_auth`，不启动或中止模型轮。ACK 只表示观察到对应消息事件，事件早于文件写入；持久化以历史读取到真实消息为准，模型轮次结果另看真实 settled。超时、断线与 `failed: <原因>` 都不证明未执行，不授权自动重投。重试在完成的助手消息上记录结果，到 `agent_settled` 才收尾未落成的等待；全部遗留 retry marker 都从请求及 `turn_end` 投影里移除，原始历史与已完成工具结果保留。

`end` 先中止当前轮、等真实空闲，再按 mode 收尾：TUI 调宿主 shutdown 恢复终端，RPC 对自身发 SIGTERM；不向第三方 PID 发强杀。手动 `/reload` 与自动升级共用空闲门，等待进程内子代理与 SDK 待处理消息，不把重载当取消。托管 RPC 的 stdout、stderr 都直接接空设备：不保存完整 RPC 事件、工具输出或任意第三方日志，不建文件、行缓冲或 App 管道；App 退出后也没有增长的输出文件、EPIPE 或 App 读端背压。

模型错误由公开的完成消息与 settled 事件上报；CuePad 自己观察到的预检、压缩及内部操作错误通过既有 ACK 或 state 报出。`/compact` 等真实结果才回 ACK，不设提前成功窗口；超过确认时限的失败仍由公开 `session_compact_failed` 事件进入状态，原生手动与自动压缩共用这条收尾，取消不记成失败。其他扩展命令没有公开完成/错误回调，交出后不回成功 ACK，等待以 `ackTimeout` 或 `sessionEnded` 表达结果未确认，不能自动重投。第三方扩展只在 RPC stdout 上输出的错误原文不可观测，不冒充已执行成功；启动即退出只报告退出事实，不承诺保留报错原文。

`ack` 只回给发命令的连接；多个客户端同连一个会话时各自收到全部状态，扩展不仲裁。

FireCode 经两个频道把事实交给扩展：`firecode:workers`（`{inFlight}`，在飞子代理数）与 `firecode:subagents`（`{workers}`，名册原文）。扩展不读 FireCode 的档案与会话文件。

dsh 的随包插件（`dsh-cuepad.mjs`，每次启动经 `--patch` 叠上）与 CuePad 之间的扩展方法、通知与环境变量只写在插件的头注释里。

## 已知边界

- 会话冻结（SIGSTOP）或机器休眠造成的假死发现不了：既定取舍，不做心跳。
- 跳到终端定位不到 herdr 这类再套一层的复用器里的 pane。
- 终端里的 Grok Build 只读：CuePad 碰不到它的输入，只从它的会话记录看它在做什么，看不到它在等你确认（`GrokRuntime`）。
- 不用 FSEvents（延迟实测数据见 `FileFollower`、`DirectoryWatcher` 的头注释）。
