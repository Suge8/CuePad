# CueBridge —— Agent 桥（macOS）

各家 Agent 的规则只写在类型的头注释里（各家与别家不同的事实在各自 `+Facts` 文件的 `AgentFacts`）；这里只记 Pi 桥扩展的线上约定与已知边界。

## 支持范围

Pi 最低 1.4.0；生命周期与重试在未改动的官方 npm 1.4.0 原包上验证（Node 26.13.0、Bun 1.4.4）。不需要 fork 或修改用户配置。
RPC 扩展对自身发 SIGTERM 是这版运行时的已验证收尾路径，不是公开 SDK 对任意未来版本的保证。

## 协议

Pi 的桥扩展（`Extension/cuepad-bridge/`，随 App 打包，CuePad 托管的 pi 经 `--extension` 载入）与 `PiWire` 之间的线上约定。消息与字段以两边源码为准；这里只记代码里写不下的约定。

- 传输：Unix socket，一行一个 JSON（`\n` 结尾）。路径 `<socket 目录>/<sessionId>.<pid>.sock`，缺省目录 `/tmp/cuepad-<uid>`（`sun_path` 上限 104 字节，所以不用 `$TMPDIR`）；权限与改名的做法在 `connection.ts`。
- 版本声明的精确格式 `const EXTENSION_VERSION = <数字>;` 是兼容接口：在跑的扩展核对磁盘、Swift 的随包版本读取、Python 的 lint 与同步测量（共用 `apple/scripts/_pi_extension.py`）都按它解析。数字只在入口声明一份；不再增加 JSON 清单或第二份配置。
- 版本：`EXTENSION_VERSION`（入口 `index.ts` 里）是唯一的版本号（`PiExtensionBundle.version` 从文件解析），扩展改了就升。会话握手时报的版本与随包版本不同（App 更新前起的托管会话还跑着旧版），CuePad 发 `upgrade`；扩展读它所在目录（App 里随包的那份）的版本，不同就等会话连同子代理都歇下时重新载入（重新载入会中断进程内子代理在飞的回合，所以可能等几个小时）。
- 兼容：CuePad 读得懂从 `PiWire.oldestExtension` 到随包版本的扩展，等换新扩展的这段照常收发。只加命令、加 CuePad 可以没有的字段不提它，旧扩展不认的命令回 `bad_request`；改了 CuePad 读的格式、已有命令的含义，或 CuePad 要靠新字段才对时提到那一版。区间外的会话只读出身份、不发命令，等它换上新扩展（`Session.upgrading`）。
- `CUEPAD_HOSTED`（后台托管）的值是空闲多少秒后自己退出：正整数；缺省或不是正数就不是托管。
- 连接断开只表示下线。显式结束要等 `bye quit` 后断开；重载、切换与未告别断线不报结束成功。同一 Pi 会话的全部已知承载进程都收尾后才完成。

`{"t":"upgrade"}`：请扩展核对磁盘上的扩展版本。不带 `id`，扩展不回 `ack`，CuePad 读不懂的扩展也发。
**这一行的格式永远不能变**，扩展也要一直认它：要叫醒的也有 CuePad 读不懂的旧扩展，它们只认得出这一行（与 hello 里身份那几项、`bye`）；格式一变，旧会话就再也换不上新扩展（与随包扩展在 App 里的路径必须稳定是同一类约束）。

`ack` 只回给发命令的连接；多个客户端同连一个会话时各自收到全部状态，扩展不仲裁。`quota` 的 `ack.ok` 只代表命令已处理，不代表获得数值观测。

`end` 只对自身发 SIGTERM，不向第三方 PID 发强杀。

网关成功清单的 `accounts` 与 `activeScopes` 同事务更新，只移除该来源已经撤销的账号；损坏清单不部分写入。

magpie v0.1.2190 的 [公开结构](https://github.com/yetone/magpie/blob/v0.1.2190/internal/provider/quotas.go) 与[网关接口](https://github.com/yetone/magpie/blob/v0.1.2190/internal/gateway/gateway.go)已核对。GET `/v1/magpie/quotas` 不保证更新 Claude 观测：Claude Code 回答或 `/usage` 才更新。官方另有 POST `/v1/magpie/quotas/refresh`，可能在账号目录运行 CLI；CuePad 不自动调用它，不复制上游登录或以反复 GET 冒充实时刷新。

单网关不显示来源标签，多来源时才按已有 Mac 名称与同机网关编号区分，不把地址拼进账号名；明细里同一产品只有一个账号时只写产品名，有几个时才接账号名（邮箱的 @ 前那段不重复就只写它，全名在悬停提示里）。

## 调试

手动起一个连上隔离实例的 Pi 会话：`CUEPAD_PI_SOCKET_DIR=$(python3 apple/scripts/app.py sockets) CUEPAD_HOSTED=3600 pi --mode rpc -e apple/CuePadKit/Sources/CueBridge/Extension/cuepad-bridge`（扩展目录就是随包的那份）。终端里的 `pi` 不上桥。

## 已知边界

- 会话冻结（SIGSTOP）或机器休眠造成的假死发现不了：既定取舍，不做心跳。
- 不用 FSEvents（延迟实测数据见 `FileFollower`、`Socket.swift` 里 `DirectoryWatcher` 的头注释）。
