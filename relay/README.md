# CuePad 中转

Bun 服务，无第三方依赖。门铃让同一个人的几台设备即时知道"iCloud 里有新东西了"：

- 一台设备的改动被 iCloud 收下后，经中转按一下门铃。
- 其它设备听到门铃，立刻去 iCloud 拉一次。

门铃不带内容，资料仍从 iCloud 拉。实时通话共用这条连接传递端到端加密的建连与控制信令，声音在手机与语音服务之间直连；中转只看到路由与密文，不读取通话正文。可选的实时活动转发会让个人内容、计数与活动推送令牌瞬时经过中转内存。两种转发都不落盘、不记录请求或响应内容，也没有令牌库或重试队列。

门铃认证只用房间号和签名。房间号是一把公钥，由你 iCloud 里的密钥派生；进房间要用这把密钥签名。没有密钥的人进不了你的房间，也按不了你的门铃。协议写在 `server.ts` 的头注释里。

中转连不上时 CuePad 照常按节奏去 iCloud 拉，只是别的设备的改动要晚一两秒才到。

## 自己架一个

正式版连作者的 `relay.cue-pad.com`。fork 可使用这台的门铃，房间由各自 iCloud 密钥派生；实时活动则需要自己的中转与 APNs 密钥，作者服务只支持作者的 App topic。按下面部署后修改 `CUEPAD_RELAY_HOST`（第 7 步）。以下是 Ubuntu 24.04 上的部署方式：无特权 Bun 由 systemd 常驻，Caddy 在 443 终止 TLS、自动续证。

1. 准备一台大陆直连线路好的服务器（香港 CN2/CMI 一类即可，1 核 1 GB 够用），开放 80（签证书）与 443，给它配一个域名。没有域名时可以先用 `<IP 用横杠连起来>.sslip.io`（如 `154-12-24-171.sslip.io`），它直接解析到这个 IP。
2. 装 Bun（1.4.4 或更新）到系统目录，`/usr/local/bin/bun`：

   ```bash
   curl -fsSLO https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip
   python3 -m zipfile -e bun-linux-x64.zip /tmp/bun && install -m 755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun
   ```

3. 建无特权用户，拷代码：

   ```bash
   useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cuepad-relay
   mkdir -p /opt/cuepad-relay && cp server.ts activity.ts apns.ts ingress.ts auth.ts voice.ts /opt/cuepad-relay/   # root 所有，服务只读
   ```

4. 把 [`cuepad-relay.service`](cuepad-relay.service) 拷到 `/etc/systemd/system/`，然后 `systemctl daemon-reload && systemctl enable --now cuepad-relay`。`systemd-analyze security cuepad-relay` 应在 1.5 左右（OK）。
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

日常维护：日志 `journalctl -u cuepad-relay`、`journalctl -u caddy`；升级中转就把上述六个 `.ts` 文件一起拷进 `/opt/cuepad-relay/` 再 `systemctl restart cuepad-relay`（设备几秒内自动重连）；升级 Bun 按第 2 步重装后同样重启。重启会结束经这台中转控制的手机通话，用户需重新发起；既有业务请求和结果不重投。

## 通话信令

协议总览在 `server.ts` 头注释，信令形状在 `voice.ts` 与原生 `VoiceSignaling.swift` 中。这里只扩展中转能力；手机直接通话还需要配套 App 与在线的 Cue Mac。

## 入口限频

Bun 内存里的一个入口令牌桶同时保护 `/v1/activity` 请求与 `/v1/<房间号>` WebSocket 握手，限额与算法在 `ingress.ts`，不提供运行期调参。这是单进程、按来源 IP 的限制，不是全局配额或抗 DDoS 保证；重启会重置预算，分布式来源仍须网络层防护。

默认只按 Bun socket 对端 IP 识别来源，忽略所有转发头。仅设 **`TRUST_PROXY=loopback`**、显式绑定回环 `HOST` 且未启用 Bun TLS 时信任回环代理。

Caddy 使用默认 `reverse_proxy` 行为：丢弃外部客户端自报的转发头，再写入实际对端 IP 与协议；不要配置 `trusted_proxies` 或透传客户端的这些头。本机回环是信任边界，本机进程也能冒充代理，不把不可信进程放在中转宿主上。直接用 Bun TLS 时不设 `TRUST_PROXY`。

## 实时活动转发

这是服务端接口；部署它不会自动启用 App 的实时活动推送。令牌即能力：只持有该活动推送令牌的调用方可以更新或结束它。调用中转时令牌放请求体，不放 URL，不在终端历史、代理访问日志或错误采集中记录。中转到 APNs 的路径按 Apple 协议携带令牌，只经 TLS 发送。

`POST /v1/activity` 的请求格式与限制在 `activity.ts`，APNs 的连接、超时、在途上限与错误映射在 `apns.ts`。

手机暂时离线时，**APNs 可以暂存待送通知**，按折叠标识合并同一活动的更新，并尝试在到期前补送最新状态或结束事件；中转本身仍不存库、不排队、不重试。Apple 明确这是尽力服务，不保证严格保留最新一份、顺序、到期边界或最终送达。

成功返回 **204，只表示 APNs 已接受**，不保证手机收到或岛已经显示。超时（504）与断线都不能证明 APNs 未接受，不要据此宣称未送达或已显示。

### 启用前

`GET /v1/activity/health` 是本地就绪检查：配置完整、私钥已加载且启动时 ES256 签名成功，返回 **204**；未配置返回 **503**。检查不建立 APNs 连接、不发送推送，也不证明 Apple 侧密钥权限、网络可达性或设备送达。

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

一个 1 核 1 GB 的进程能扛几千条连接。每千个活跃用户每月大约 60 GB 流量，主要是心跳。
