# CuePad 中转

Bun 服务，无第三方依赖。门铃让同一个人的几台设备即时知道"iCloud 里有新东西了"，自己去 iCloud 拉；同一条连接还转发通话信令与实时活动推送。都不落盘、不记录内容。房间由各自 iCloud 里的密钥派生，没有密钥进不了房间。协议在 `server.ts` 头注释。中转连不上时 App 照常按节奏去 iCloud 拉。

## 自己架一个

正式版连作者的 `relay.cue-pad.com`。fork 可以用这台的门铃；实时活动要自己的中转与 APNs 密钥（作者的只认作者 App 的 topic）。以下是 Ubuntu 24.04：无特权 Bun 由 systemd 常驻，Caddy 在 443 终止 TLS、自动续证。

1. 准备一台大陆直连线路好的服务器（香港 CN2/CMI 一类，1 核 1 GB 够用），开放 80 与 443，配一个域名（没有时可先用 `<IP 用横杠连起来>.sslip.io`）。不要放在 Cloudflare、Vercel 的默认域名后面：大陆遭 DNS 污染、按 SNI 阻断。
2. 装 Bun（1.4.4 或更新）到 `/usr/local/bin/bun`：

   ```bash
   curl -fsSLO https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip
   python3 -m zipfile -e bun-linux-x64.zip /tmp/bun && install -m 755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun
   ```

3. 建无特权用户，拷代码：

   ```bash
   useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cuepad-relay
   mkdir -p /opt/cuepad-relay && cp server.ts activity.ts apns.ts ingress.ts auth.ts voice.ts /opt/cuepad-relay/   # root 所有，服务只读
   ```

4. 把 [`cuepad-relay.service`](cuepad-relay.service) 拷到 `/etc/systemd/system/`，`systemctl daemon-reload && systemctl enable --now cuepad-relay`。
5. 按 [Caddy 官方文档](https://caddyserver.com/docs/install#debian-ubuntu-raspbian) 用 apt 装 Caddy，`/etc/caddy/Caddyfile` 写成下面这样再 `systemctl reload caddy`。用默认的 `reverse_proxy`，不配 `trusted_proxies`、不透传客户端自报的转发头：限频按 Caddy 写入的对端 IP 算。

   ```
   relay.example.com {
   	reverse_proxy 127.0.0.1:8080
   }
   ```

6. `curl https://relay.example.com/health` 返回 `ok`。要实时活动的，`/v1/activity/health` 还须返回 204（见下）；发布脚本两样都核对。
7. 把 `apple/App/Config/Signing.xcconfig` 的 `CUEPAD_RELAY_HOST` 换成你的域名，重新编译 App。
8. 你自己的 iCloud 容器里要有记录类型 `relaySecrets`：按 [apple/scripts/AGENTS.md](../apple/scripts/AGENTS.md)「CloudKit 数据结构」导入 `apple/CloudKit/cuepad.ckdb`。

不装 Caddy 也可以让 Bun 自己提供 TLS（`CERT`、`KEY`，见 `server.ts` 头注释），证书续期后要重启。

升级：六个 `.ts` 一起拷进 `/opt/cuepad-relay/` 再 `systemctl restart cuepad-relay`。重启会挂断经这台中转的手机通话。

## 实时活动

五项全不配时门铃照常，活动接口返回 503；只配一部分或私钥读不出，服务起不来。

| 环境变量 | 值 |
| --- | --- |
| `APNS_KEY_FILE` | 服务可读的 `.p8` 私钥文件绝对路径 |
| `APNS_KEY_ID` | Apple 的 10 位 Key ID |
| `APNS_TEAM_ID` | Apple 的 10 位 Team ID |
| `APNS_TOPIC` | `<App bundle ID>.push-type.liveactivity` |
| `APNS_ENVIRONMENT` | `production` 或 `development` |

- 在 Apple 后台建只限一个 topic、一个环境的钥匙；开发与生产各部署一个进程。代码看不出 `.p8` 在 Apple 侧的权限，`/v1/activity/health` 的 204 也不证明它。
- 私钥用 systemd `LoadCredential` 交给服务（`APNS_KEY_FILE` 指向该 credential），不写进环境变量、镜像或日志；加 `LimitCORE=0`，免得内存里的推送内容随 core dump 落盘。轮换或撤销钥匙后重启。
- 推送令牌即能力：代理与日志不记录请求体与授权头。
