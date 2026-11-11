# CuePi —— Agent 桥（macOS）

各家 Agent 的规则只写在类型的头注释里（各家与别家不同的事实在各自 `+Facts` 文件的 `AgentFacts`）；这里只记 Pi 桥扩展的线上约定与已知边界。

## 支持范围

Pi 最低 1.4.0；生命周期与重试在未改动的官方 npm 1.4.0 原包上验证（Node 26.13.0、Bun 1.4.4）。不需要 fork 或修改用户配置。
RPC 扩展对自身发 SIGTERM 是这版运行时的已验证收尾路径，不是公开 SDK 对任意未来版本的保证。

## 协议

Pi 的桥扩展（`Extension/cuepad-bridge/`，装成 Pi 扩展目录下的同名目录）与 `PiWire` 之间的线上约定。字段的语义与上报时机见扩展源码的注释；这里只列消息与字段。

- 传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，所以不用 `$TMPDIR`）；权限与改名的做法在 `connection.ts`。
- 版本声明的精确格式 `const EXTENSION_VERSION = <数字>;` 是兼容接口：在跑的扩展核对磁盘、Swift 的随包版本读取、Python 的 lint 与同步测量（共用 `apple/scripts/_pi_extension.py`）都按它解析。数字只在入口声明一份；不再增加 JSON 清单或第二份配置。
- 版本：`EXTENSION_VERSION`（入口 `index.ts` 里）是唯一的版本号（`PiExtensionBundle.version` 从文件解析），扩展改了就升。会话握手时报的版本与随包版本不同，或 CuePad 装完新版扩展后，CuePad 发 `upgrade`；扩展读磁盘上的版本，不同就等会话连同子代理都歇下时重新载入（重新载入会中断进程内子代理在飞的回合，所以可能等几个小时）。
- 兼容：CuePad 读得懂从 `PiWire.oldestExtension` 到随包版本的扩展，等换新扩展的这段照常收发。只加命令、加 CuePad 可以没有的字段不提它，旧扩展不认的命令回 `bad_request`；改了 CuePad 读的格式、已有命令的含义，或 CuePad 要靠新字段才对时提到那一版。区间外的会话只读出身份、不发命令，等它换上新扩展（`Session.upgrading`）。
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
| `info` | 只带变了的项（没出现的键不变，`null` 是新值）：`name`、`firstMessage`、`question{id, kind, text, options}`、`subagents[{name, role, state, action, startedAt, settledAt, model}]`、`model{provider, id, name, thinking, images, supportsFast, account{kind, scope, source?, route?, name?}}`、`thinking`、`fast`、`models`、`proofs[{provider, id, account, at}]`、`context{tokens, window}`、`commands[{name, description, source, hint}]` |
| `draft` | 正在说的话：`text`（`null` 是清掉）、`since` |
| `quota` | 授权的额度能力与结果：`provider`（模型在 Pi 里的提供方；网关清单 `accounts` 里是上游）、`account{kind, scope, source?, route?, name?}`、`status`（`observed`/`unobserved`/`unsupported`/`failed`）、`windows[{seconds, used, resetsAt, model, binding}]`、`complete`、`observedAt?`（原观测的 Unix 秒）、`activeScopes?`（此来源成功返回的账号分区）、`accounts?`（同一次网关清单中的各账号报告）、`details?{kind, plan?, balance?, values[]}`、`requestedAt?`（排序时刻的 Unix 秒：主动查询取请求开始，回复带回的取收到回复）、`owners?`（网关来源一级：这次解析到这个来源的每个 Pi 提供方与各自开始解析的 Unix 秒） |
| `ack` | 命令回应：`id`、`ok`，或 `error`（见下表）；`reload` 另带 `reloaded` |
| `bye` | 主动关闭前：`reason`（`quit`/`new`/`resume`/`fork`/`reload`） |

`account.kind` 来自宿主认证事实（`oauth`/`apiKey`）；`scope` 是请求授权的不可逆分区，不传凭据。原生订阅只为当前模型的提供方解析授权；其他提供方的原生 OAuth 只报种类与 `scope=null`，主动查额度时再解析。未解析的授权（`scope=null`）是这个提供方的一条，不关联任何账号的数值：主动查询时解析失败报带 `requestedAt` 的 `failed`，其他提供方还没查的报能力；能力声明不带排序时刻，不报失败；解析失败不归到之前的账号。`proofs` 是这个会话解析成功过的每个模型（含模型范围外、额度查询解析到的）最近一次证明的授权与开始解析的时刻（Unix 秒）：每次成功都推进，解析失败不抹掉。CuePad 怎么据此保留与移除记录在 `AccountQuota+Store`。几个提供方指向同一网关时查询只做一次，报告的 `owners` 列出全部。实际地址与认证经宿主 `getApiKeyAndHeaders(model)` 取得，自定义地址不调用原生订阅接口。回复流里的额度只在回合前已报告的原生 OAuth 分区与收到回复后重新解析的一致时归到它，不一致就丢掉这次并重报模型身份。

自定义来源从模型实际 baseUrl 下的 `magpie/quotas` 查询（`quota-gateway.ts`），复用请求认证与配置头，不另存网关地址或密钥；不支持与失败怎么报在那里。网关账号以 `source`（实际地址与认证的不可逆分区）、完整上游 `route` 与 user 分开；可选 `name` 只作显示。成功清单的 `accounts` 用清单的 `requestedAt`，与 `activeScopes` 同事务更新，只移除该来源已经撤销的账号；损坏清单不部分写入。主动查询的成功、失败与不支持结果和回复带回的观测都带 `requestedAt`。原生查询的 `observedAt` 取响应解析完成时刻，回复取收到时刻，网关账号仍保留自己的 `readAt`。

什么时候查、怎么合并与冷却在 `AccountQuotas`，怎么显示在 `QuotaMeter`，模型额度环关联哪个账号在 `ModelQuota`。网关账号的原观测时间只认 `readAt`，`asOf` 与取缓存的时刻不代替它；明细里刚观测过的账号并成一行原观测时间（取其中最早的），陈旧、失败、过期标在各自账号上。

magpie v0.1.2190 的 [公开结构](https://github.com/yetone/magpie/blob/v0.1.2190/internal/provider/quotas.go) 与[网关接口](https://github.com/yetone/magpie/blob/v0.1.2190/internal/gateway/gateway.go)已核对。GET `/v1/magpie/quotas` 不保证更新 Claude 观测：Claude Code 回答或 `/usage` 才更新。官方另有 POST `/v1/magpie/quotas/refresh`，可能在账号目录运行 CLI；CuePad 不自动调用它，不复制上游登录或以反复 GET 冒充实时刷新。

单网关不显示来源标签，多来源时才按已有 Mac 名称与同机网关编号区分，不把地址拼进账号名；明细里同一产品只有一个账号时只写产品名，有几个时才接账号名（邮箱的 @ 前那段不重复就只写它，全名在悬停提示里）。

ChatGPT plan（`openai` OAuth）当前没有公开额度查询能力，报 `unsupported`，管理入口为 https://chatgpt.com/settings/usage；不调用 Codex 用量接口。`ack.ok` 只代表命令已处理，不代表获得数值观测。

普通生成 `stopReason=length` 保留 `draft`，终态走现有 `error`（`max_output_tokens`）；历史保留部分文字及未完成记录。

`state.kind`：`idle`、`thinking`、`tool`（`tool`、`detail`）、`waiting_user`（`title`）、`delegating`（自己歇下、子代理在飞）、`compacting`、`done`、`error`（`error`）。

CuePad → 扩展（都带 `id`）：

| `t` | 字段 | 拒绝 |
| --- | --- | --- |
| `send` | `text`（以提示词模板或 skill 的名字开头时由 Pi 展开，同在 Pi 里打出来；文件写成一行"附件：文件名（本机路径）"，会话看不了图时图片也这样写，`AttachmentFiles.agentLine`）、`images[{mimeType, data}]`（base64 原图）、`deliveryId`（可选，落盘为消息上的 `cuepadDelivery`）、`cueTurn{deliveryId}`（可选，见下） | `empty`、`bad_request`、`unconfirmed_turn`、`user_turn` |
| `command` | `text`：`/` 开头的整行（内置与扩展命令；模板与 skill 也认，但 CuePad 经 `send` 交出它们） | `bad_request`、`unknown_command`、`missing_argument`、`unknown_model`、`no_auth` |
| `config` | `model{provider, id}`、`thinking`、`fast`、`name`，至少一项 | `bad_request`、`unknown_model`、`no_auth` |
| `answer` | `promptId`、`value`（`confirm` 为布尔，`select` 为选项原文，`text` 为字符串） | `no_prompt`、`stale_prompt`、`bad_answer` |
| `abort` | — | — |
| `abortTurn`（60 起） | `deliveryId`、`turnStartedAt`（Unix 毫秒）：只停止该投送的指定实际模型回合；接收端同步核对当前真实消息与回合时间后停止，不清空后续排队工作；旧扩展和未实现此合同的接入明确拒绝 | `bad_request`、`stale_turn` |
| `retry` | — | `nothing_to_retry` |
| `end` | — | — |
| `reload` | — | — |
| `quota` | — | — |
| `title` | `instructions`（给模型的说明）、`text`（会话的第一句话）、`timeoutMs`：回 `ack` 的 `title` 是模型的原话，CuePad 整理成名字（`SessionNameSuggestion.cleaned`，空的算失败），不写回会话（CuePad 核对后用 `config` 改名），v63 起（之前的要 `limit`） | `bad_request`、`no_model`、`failed: <原因>` |

`{"t":"upgrade"}`：请扩展核对磁盘上的扩展版本。不带 `id`，扩展不回 `ack`，CuePad 读不懂的扩展也发。
**这一行的格式永远不能变**，扩展也要一直认它：要叫醒的也有 CuePad 读不懂的旧扩展，它们只认得出这一行（与 hello 里身份那几项、`bye`）；格式一变，旧会话就再也换不上新扩展（与扩展装在 Pi 扩展目录下的路径必须稳定是同一类约束）。

`send` 缺省是人类发送；`cueTurn` 出现即是 Cue 的发送策略，空对象没有接管忙轮的许可。桥在实际派发前按 Store 权威的 Unix 毫秒表示核对当前 peer 的轮次时间与 `SendPolicy.cue`；扩展在停止、提交与推进排队消息前，以 SDK 的忙闲事实及当前投影最后一条用户消息的 `cuepadDelivery` 核对许可标识。SDK 有待处理消息时，即使 `isIdle` 为真也不放行 Cue：公开接口没有队列来源证据，不能用当前轮的许可抢先。缺证据回 `unconfirmed_turn`，标识不同回 `user_turn`，都未提交这句话、也不打断原轮。不按会话名字、目录或是否托管过滤辅助 RPC。

`send` 的新回合请求统一入队，预检中的队首也在队内；预检回来按当下忙闲继续推进，忙时停当前轮并等待歇下，空闲时同步交出。普通 `abort` / `end` 收回所有未交出的消息（含预检中），`abortTurn` 只停止匹配的当前回合，不清空队列。

`send` / `retry` 交出前通过公开 modelRegistry 核对当前模型及授权；明确缺授权回 `no_auth`，不启动或中止模型轮。ACK 只表示观察到对应消息事件，事件早于文件写入；持久化以历史读取到真实消息为准，模型轮次结果另看真实 settled。超时、断线与 `failed: <原因>` 都不证明未执行，不授权自动重投。重试在完成的助手消息上记录结果，到 `agent_settled` 才收尾未落成的等待；全部遗留 retry marker 都从请求及 `turn_end` 投影里移除，原始历史与已完成工具结果保留。

`end` 先中止当前轮、等真实空闲，再按 mode 收尾：TUI 调宿主 shutdown 恢复终端，RPC 对自身发 SIGTERM；不向第三方 PID 发强杀。手动 `/reload` 与自动升级共用空闲门，等待进程内子代理与 SDK 待处理消息，不把重载当取消。托管 RPC 的 stdout 与 stderr 怎么接在 `ChildProcess`、`PiRuntime`：不保存完整 RPC 事件、工具输出或任意第三方日志。

模型错误由公开的完成消息与 settled 事件上报；CuePad 自己观察到的预检、压缩及内部操作错误通过既有 ACK 或 state 报出。`/compact` 等真实结果才回 ACK，不设提前成功窗口；超过确认时限的失败仍由公开 `session_compact_failed` 事件进入状态，原生手动与自动压缩共用这条收尾，取消不记成失败。其他扩展的命令交出即回 ACK：Pi 在任何检查之前同步调起处理函数，忙时也执行、没有拒收的路，ACK 证明 Pi 执行了它；处理函数的完成与出错没有公开回调，第三方扩展的错误原文只在 Pi 自己的界面或 RPC stdout 上，不可观测。启动即退出带上 Pi 在 stderr 里说的最后一句。

`ack` 只回给发命令的连接；多个客户端同连一个会话时各自收到全部状态，扩展不仲裁。

FireCode 交给扩展的两个频道见 `index.ts`。

dsh 的随包插件（`dsh-cuepad.mjs`，每次启动经 `--patch` 叠上）与 CuePad 之间的扩展方法、通知与环境变量只写在插件的头注释里。

## 已知边界

- 会话冻结（SIGSTOP）或机器休眠造成的假死发现不了：既定取舍，不做心跳。
- 跳到终端定位不到 herdr 这类再套一层的复用器里的 pane。
- 终端里的 Grok Build 只读：CuePad 碰不到它的输入，只从它的会话记录看它在做什么，看不到它在等你确认（`GrokRuntime`）。
- 不用 FSEvents（延迟实测数据见 `FileFollower`、`Socket.swift` 里 `DirectoryWatcher` 的头注释）。
