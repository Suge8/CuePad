# CuePad 中转

Bun 服务，无第三方依赖。门铃让同一个人的几台设备即时知道"iCloud 里有新东西了"：

- 一台设备的改动被 iCloud 收下后，经中转按一下门铃。
- 其它设备听到门铃，立刻去 iCloud 拉一次。

门铃不带内容，资料仍从 iCloud 拉。可选的实时活动转发会让个人内容、计数与活动推送令牌瞬时经过中转内存；中转不落盘、不记录请求或响应内容，没有账户、令牌库或重试队列。

门铃认证只用房间号和签名。房间号是一把公钥，由你 iCloud 里的密钥派生；进房间要用这把密钥签名。没有密钥的人进不了你的房间，也按不了你的门铃。协议写在 `server.ts` 的头注释里。

中转连不上时 CuePad 照常按节奏去 iCloud 拉，只是别的设备的改动要晚一两秒才到。

## 自己架一个

正式版连作者的中转 `relay.cue-pad.com`。自己编译的默认也连它：房间由你自己 iCloud 里的密钥派生，和别人互不相干；想用自己的就照下面架一台，再改 `CUEPAD_RELAY_HOST`（第 7 步）。下面是作者的中转实际的部署方式（Ubuntu 24.04）：Bun 用无特权用户跑在本机端口，由 systemd 常驻并加固；Caddy 在 443 终止 TLS、自动申请证书，把连接转给 Bun。

1. 准备一台大陆直连线路好的服务器（香港 CN2/CMI 一类即可，1 核 1 GB 够用），开放 80（签证书）与 443，给它配一个域名。没有域名时可以先用 `<IP 用横杠连起来>.sslip.io`（如 `154-12-24-171.sslip.io`），它直接解析到这个 IP。
2. 装 Bun（1.4.4 或更新）到系统目录，`/usr/local/bin/bun`：

   ```bash
   curl -fsSLO https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip
   python3 -m zipfile -e bun-linux-x64.zip /tmp/bun && install -m 755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun
   ```

3. 建无特权用户，拷代码：

   ```bash
   useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cuepad-relay
   mkdir -p /opt/cuepad-relay && cp server.ts activity.ts apns.ts ingress.ts /opt/cuepad-relay/   # root 所有，服务只读
   ```

4. 写 `/etc/systemd/system/cuepad-relay.service`，然后 `systemctl daemon-reload && systemctl enable --now cuepad-relay`：

   ```ini
   [Unit]
   Description=CuePad relay
   After=network-online.target
   Wants=network-online.target

   [Service]
   User=cuepad-relay
   Group=cuepad-relay
   WorkingDirectory=/opt/cuepad-relay
   Environment=HOST=127.0.0.1 PORT=8080 TRUST_PROXY=loopback
   ExecStart=/usr/local/bin/bun server.ts
   Restart=always
   RestartSec=2
   NoNewPrivileges=yes
   ProtectSystem=strict
   ProtectHome=yes
   PrivateTmp=yes
   PrivateDevices=yes
   ProtectKernelTunables=yes
   ProtectKernelModules=yes
   ProtectKernelLogs=yes
   ProtectControlGroups=yes
   ProtectClock=yes
   ProtectHostname=yes
   ProtectProc=invisible
   ProcSubset=pid
   RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
   RestrictNamespaces=yes
   RestrictRealtime=yes
   RestrictSUIDSGID=yes
   LockPersonality=yes
   CapabilityBoundingSet=
   AmbientCapabilities=
   SystemCallArchitectures=native
   SystemCallFilter=@system-service
   UMask=0077

   [Install]
   WantedBy=multi-user.target
   ```

   不要加 `MemoryDenyWriteExecute`：Bun 的 JIT 要可写可执行的内存。`systemd-analyze security cuepad-relay` 应在 1.5 左右（OK）。
5. 按 [Caddy 官方文档](https://caddyserver.com/docs/install#debian-ubuntu-raspbian) 用 apt 装 Caddy，`/etc/caddy/Caddyfile` 写成（换成你的域名，可以写多个），再 `systemctl reload caddy`：

   ```
   relay.example.com {
   	reverse_proxy 127.0.0.1:8080
   }
   ```

   Caddy 会自己签证书、续期，WebSocket 原样转发。域名还没解析到这台时签不到，Caddy 会退避重试；解析生效后 `systemctl reload caddy` 立即重试。
6. 门铃检查：`curl https://relay.example.com/health` 返回 `ok`。需要实时活动的版本，发布前还须 GET `/v1/activity/health` 确认 HTTP 204（见下）；门铃正常不代表 APNs 已配置。
7. 把 `apple/App/Config/Signing.xcconfig` 的 `CUEPAD_RELAY_HOST` 换成你的域名，再重新编译 App。
8. 你自己的 iCloud 容器里要有记录类型 `relaySecrets`，按 [docs/release.md](../docs/release.md)「CloudKit 数据结构」导入 `apple/CloudKit/cuepad.ckdb`。

不想装 Caddy 的，也可以让 Bun 自己提供 TLS（`CERT`、`KEY` 环境变量，见 `server.ts` 头注释），证书续期后要重启服务。

日常维护：日志 `journalctl -u cuepad-relay`、`journalctl -u caddy`；升级中转就把四个 `.ts` 文件一起拷进 `/opt/cuepad-relay/` 再 `systemctl restart cuepad-relay`（设备几秒内自动重连）；升级 Bun 按第 2 步重装后同样重启。

## 入口限频

Bun 内存里的一个入口令牌桶同时保护 `/v1/activity` 请求与 `/v1/<房间号>` WebSocket 握手，在读活动请求体、调用 APNs、分配 WebSocket 前计费；无效请求也计费，已建立连接的门铃帧不计费。两项健康检查不计费。

- 每个来源 IP 共用 **每秒 10 次、突发 60 次**预算，连续补充，每次请求用一份；多台设备共用出口时共享预算。正常一台 Mac 每秒最多发布一份，留出多设备与重连余量。
- 过限立即返回 **429**、`{"reason":"RateLimited"}`、整数秒 `Retry-After` 与 `Cache-Control: no-store`；不排队、不自动重试。`Retry-After` 向上取整、至少 1 秒，表示当前预算最早恢复时间，不预留名额。
- 来源表最多 **16,384 项**。满表时拒绝新来源，不驱逐仍有预算债务的旧来源；已有来源继续按自己的预算处理。此时 `Retry-After` 指向最早可回收的槽位。
- 表只保留 IP 和限频元数据，不保存业务内容、活动令牌或请求历史。使用单调时钟；最后一次获准请求后 **6 秒**预算已补满，拒绝请求不延长该时刻。按最后获准时间维护双向链表，每次请求至多回收最旧的一项，无扫描、排序、定时清扫或等待；单次表操作均摊 O(1)，空闲时不为删除过期项唤醒进程。表不落盘、不记 IP 日志，进程退出即丢弃。
- 这是单进程、按来源 IP 的限制，不是全局配额或抗 DDoS 保证；重启会重置预算，分布式来源仍须网络层防护。限额固定在 `ingress.ts`，不提供运行期调参接口。

默认只按 Bun socket 对端 IP 识别来源，忽略所有转发头；IPv6 规范化，IPv4-mapped IPv6 与对应 IPv4 共用预算。仅设 **`TRUST_PROXY=loopback`**、显式绑定回环 `HOST` 且未启用 Bun TLS 时信任回环代理。该模式要求 socket 对端是回环地址、`X-Forwarded-For` 是单个有效 IP、`X-Forwarded-Proto` 是 `http` 或 `https`；缺失、列表或非法值返回 400，不回退到别的头或来源。非法代理配置使启动失败。

Caddy 使用默认 `reverse_proxy` 行为：丢弃外部客户端自报的转发头，再写入实际对端 IP 与协议；不要配置 `trusted_proxies` 或透传客户端的这些头。本机回环是信任边界，本机进程也能冒充代理，不把不可信进程放在中转宿主上。直接用 Bun TLS 时不设 `TRUST_PROXY`。

## 实时活动转发

这是服务端接口；部署它不会自动启用 App 的实时活动推送。令牌即能力：只持有该活动推送令牌的调用方可以更新或结束它。调用中转时令牌放请求体，不放 URL，不在终端历史、代理访问日志或错误采集中记录。中转到 APNs 的路径按 Apple 协议携带令牌，只经 TLS 发送。

`POST /v1/activity`，`Content-Type: application/json`，仅 HTTPS：

```json
{
  "token": "活动推送令牌的十六进制字符串",
  "environment": "production",
  "priority": 5,
  "expiration": 1793260800,
  "payload": {
    "aps": {
      "timestamp": 1793232000,
      "event": "update",
      "content-state": {"由调用方提供": "匹配 App 的 ContentState"},
      "stale-date": 1793232180
    }
  }
}
```

- `environment` 只接受 `production` / `development`，且须与服务配置一致；`priority` 只接受 5 / 10。
- `event` 只接受 `update` / `end`；`timestamp` 必填，`stale-date` / `dismissal-date` 可选，均为非负整数 Unix 秒。结束时仍需最终 `content-state`；立即移除锁屏活动可用 `dismissal-date: 0`。
- `expiration` 必填，取该活动真实到期时刻（Mac 的 `ActivityDestination.expiresAt`），为非负整数 Unix 秒，须满足 `timestamp <= expiration <= timestamp + 8 小时`；不能每次发送都重新延长活动寿命。`update` / `end` 使用相同规则，`dismissal-date` 不改变推送到期时刻。
- `content-state` 是不解释的 JSON 对象；只有外层的固定字段获准，不能传 `alert`、`start`、topic、目的 URL 或其它 APNs 字段。查询参数一律拒绝。
- 请求总量最多 16 KiB；APNs payload 重编码后的 UTF-8 最多 4096 字节。令牌接受偶数位十六进制、最多 1024 字符，不假设固定令牌长度。不接受压缩请求。
- APNs topic 由服务端固定，推送类型固定 `liveactivity`。`apns-expiration` 使用请求的活动到期时刻；`apns-collapse-id` 是规范化为小写十六进制的令牌字符串的 SHA-256（64 字符 hex），同一活动的更新与结束共享折叠标识，客户不能自定。
- 手机暂时离线时，**APNs 可以暂存待送通知**，按折叠标识合并同一活动的更新，并尝试在到期前补送最新状态或结束事件；中转本身仍不存库、不排队、不重试。Apple 明确这是尽力服务，不保证严格保留最新一份、顺序、到期边界或最终送达；204 不能当作手机已经显示。
- 中转复用 HTTP/2 连接，ES256 JWT 按需每 50 分钟刷新；单次 APNs 请求最多 10 秒，最多 32 个在途请求，并服从 APNs 的连接并发限制。首份有效认证前只发一个请求；满额立即拒绝，不排队。断线或超时会关闭连接并清掉在途请求，之后的新请求重新建连，已失败的请求不自动重发。

成功返回 **204，只表示 APNs 已接受**，不保证手机收到或岛已经显示。错误返回 JSON `{"reason":"…"}`；APNs 响应错误另带原始 `apnsStatus`：

| HTTP | 含义 |
| --- | --- |
| 400 / 413 / 415 | 字段或环境错误 / 超限 / 非 JSON 或压缩请求 |
| 405 / 426 | 非 POST / 未使用 HTTPS |
| 410 | APNs `400 BadDeviceToken`、`400 DeviceTokenNotForTopic` 或 `410 Unregistered`；令牌对当前固定环境/topic 不可用，不表示它对所有环境/topic 永久失效 |
| 429 | 入口限频 `RateLimited`（带 `Retry-After`），或 APNs 限频（保留 reason 与 `apnsStatus`） |
| 503 | 未启用 `ActivityUnavailable`、满额 `APNsBusy`、本机不可用 `APNsUnavailable` 或 APNs 暂不可用 |
| 504 | `APNsTimeout`；是否已被 APNs 接受未知 |
| 502 | 其它 APNs 错误、断线或异常响应；保留可辨 reason，不自动重试 |

认证错误（例如 `InvalidProviderToken`、`ExpiredProviderToken`、`BadEnvironmentKeyIdInToken`、`TopicDisallowed`）不转成 410。只有上表三个确切状态/reason 组合触发失效语义；其余包括 `ExpiredToken` 保留上游状态及 reason，以 502 交调用方判断。断线同样不能证明 APNs 未接受，不要据此宣称未送达或已显示。

### 启用前

`GET /v1/activity/health` 是无数据的本地就绪检查：配置完整、私钥已加载且启动时 ES256 签名成功，返回 **204**；未配置返回 **503**。响应体为空，带 `Cache-Control: no-store`；其它方法返回 405，`Allow: GET`。检查不建立 APNs 连接、不发送推送，也不证明 Apple 侧密钥权限、网络可达性或设备送达。

五项配置全缺时，门铃与 `/health` 照常可用，活动接口及活动健康检查明确返回 503；只配部分、空值、非法配置或不可读取的 P-256 私钥会使启动失败：

| 环境变量 | 值 |
| --- | --- |
| `APNS_KEY_FILE` | 服务可读的 `.p8` 私钥文件绝对路径 |
| `APNS_KEY_ID` | Apple 的 10 位 Key ID |
| `APNS_TEAM_ID` | Apple 的 10 位 Team ID |
| `APNS_TOPIC` | 完整 `<App bundle ID>.push-type.liveactivity` |
| `APNS_ENVIRONMENT` | `production` 或 `development` |

在 Apple 后台创建 **topic-specific、只限一个 topic 和一个环境**的钥匙，不用 team-scoped 或跨环境旧钥匙。代码不能从 `.p8` 判断 Apple 侧权限，部署者须核实。每个进程只有一套配置；开发与生产分开部署。上游主机只从环境选 Apple 官方主机，没有自定义 host 开关。

入口限频已由 Bun 统一执行，不需要定制 Caddy 插件；32 个 APNs 在途请求的限制另管并发，不代替限频。部署前仍须配置防火墙、反向代理请求大小与超时限制，避免慢连接与大请求在入口前耗尽资源。将私钥作为只读 secret 文件交服务（例如 systemd `LoadCredential`，`APNS_KEY_FILE` 指向该 credential），不要写进代码、镜像、环境变量值或日志；禁用 core dump（systemd `LimitCORE=0`），避免内存里的内容落盘。其余四项可放 systemd 环境配置。轮换或撤销钥匙后重启服务，清掉旧连接和签名。

公网只开放 TLS 代理，不开放 Bun 明文端口。活动接口接受 Bun 自带 TLS；用 Caddy 时按「入口限频」启用回环代理信任，同时校验来源与 HTTPS，不接受外部客户端自报的转发头。代理不要记录 body、令牌或授权头，不要启用含请求内容的追踪。发布、写入 secret、发真实推送前先获得部署授权。

协议依据：[ActivityKit 推送](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)、[APNs 请求](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)、[响应语义](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)、[钥匙与 JWT](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)。

## 门铃用量

- 每台设备一条连接：Mac 在 App 运行期间一直连着，手机只在前台时连。连着时每 10 秒发一次心跳；中转 20 秒没收到任何东西就断开那条连接，不留死连接。
- 一个 1 核 1 GB 的进程能扛几千条连接。每千个活跃用户每月大约 60 GB 流量，主要是心跳。
