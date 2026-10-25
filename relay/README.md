# CuePad 门铃中转

一个 Bun 单文件服务（`server.ts`），让同一个人的几台设备即时知道"iCloud 里有新东西了"：

- 一台设备的改动被 iCloud 收下后，经中转按一下门铃。
- 其它设备听到门铃，立刻去 iCloud 拉一次。

数据只在 iCloud 里。中转不存任何东西，门铃也不带内容。

中转只看得到两样东西：房间号和签名。房间号是一把公钥，由你 iCloud 里的密钥派生；进房间要用这把密钥签名。没有密钥的人进不了你的房间，也按不了你的门铃。协议写在 `server.ts` 的头注释里。

不架中转也能用 CuePad：设备照常按节奏去 iCloud 拉，只是别的设备的改动要晚一两秒才到。

## 自己架一个

适用于自己编译 CuePad 的情况。正式版已经连着作者的中转，不用做这些。下面是作者的中转实际的部署方式（Ubuntu 24.04）：Bun 用无特权用户跑在本机端口，由 systemd 常驻并加固；Caddy 在 443 终止 TLS、自动申请证书，把连接转给 Bun。

1. 准备一台大陆直连线路好的服务器（香港 CN2/CMI 一类即可，1 核 1 GB 够用），开放 80（签证书）与 443，给它配一个域名。没有域名时可以先用 `<IP 用横杠连起来>.sslip.io`（如 `154-12-24-171.sslip.io`），它直接解析到这个 IP。
2. 装 Bun（1.2 或更新）到系统目录，`/usr/local/bin/bun`：

   ```bash
   curl -fsSLO https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip
   python3 -m zipfile -e bun-linux-x64.zip /tmp/bun && install -m 755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun
   ```

3. 建无特权用户，拷代码：

   ```bash
   useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cuepad-relay
   mkdir -p /opt/cuepad-relay && cp server.ts /opt/cuepad-relay/   # root 所有，服务只读
   ```

4. 写 `/etc/systemd/system/cuepad-relay.service`，然后 `systemctl daemon-reload && systemctl enable --now cuepad-relay`：

   ```ini
   [Unit]
   Description=CuePad relay (doorbell)
   After=network-online.target
   Wants=network-online.target

   [Service]
   User=cuepad-relay
   Group=cuepad-relay
   WorkingDirectory=/opt/cuepad-relay
   Environment=HOST=127.0.0.1 PORT=8080
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
6. 检查：`curl https://relay.example.com/health` 返回 `ok`。
7. 把域名填进 `apple/App/Config/Signing.xcconfig` 的 `CUEPAD_RELAY_HOST`，再重新编译 App。
8. 你自己的 iCloud 容器里要有记录类型 `relaySecrets`，按 [docs/release.md](../docs/release.md)「CloudKit 数据结构」导入 `apple/CloudKit/cuepad.ckdb`。

不想装 Caddy 的，也可以让 Bun 自己提供 TLS（`CERT`、`KEY` 环境变量，见 `server.ts` 头注释），证书续期后要重启服务。

日常维护：日志 `journalctl -u cuepad-relay`、`journalctl -u caddy`；升级中转就把新的 `server.ts` 拷进 `/opt/cuepad-relay/` 再 `systemctl restart cuepad-relay`（设备几秒内自动重连）；升级 Bun 按第 2 步重装后同样重启。

## 用量

- 每台设备一条连接：Mac 在 App 运行期间一直连着，手机只在前台时连。连着时每 10 秒发一次心跳；中转 20 秒没收到任何东西就断开那条连接，不留死连接。
- 一个 1 核 1 GB 的进程能扛几千条连接。每千个活跃用户每月大约 60 GB 流量，主要是心跳。
