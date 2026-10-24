# CuePad 门铃中转

一个 Bun 单文件服务（`server.ts`），让同一个人的几台设备即时知道"iCloud 里有新东西了"：

- 一台设备的改动被 iCloud 收下后，经中转按一下门铃。
- 其它设备听到门铃，立刻去 iCloud 拉一次。

数据只在 iCloud 里。中转不存任何东西，门铃也不带内容。

中转只看得到两样东西：房间号和签名。房间号是一把公钥，由你 iCloud 里的密钥派生；进房间要用这把密钥签名。没有密钥的人进不了你的房间，也按不了你的门铃。协议写在 `server.ts` 的头注释里。

不架中转也能用 CuePad：设备照常按节奏去 iCloud 拉，只是别的设备的改动要晚一两秒才到。

## 自己架一个

适用于自己编译 CuePad 的情况。正式版已经连着作者的中转，不用做这些。

1. 准备一台大陆直连线路好的服务器（香港 CN2/CMI 一类即可，1 核 1 GB 够用），再给它配一个域名并签好证书。
2. 装 [Bun](https://bun.sh)（1.2 或更新），把 `server.ts` 拷到服务器上，例如 `/opt/cuepad-relay/`。
3. 选一种方式提供 TLS：
   - 直接用证书：`PORT=443 CERT=/path/fullchain.pem KEY=/path/privkey.pem bun server.ts`；
   - 或放在 Caddy、nginx 后面：Bun 用明文监听本机端口（`PORT=8080 bun server.ts`），由反向代理终止 TLS 并转发 WebSocket（Caddy 写一行 `reverse_proxy 127.0.0.1:8080` 即可）。
4. 交给 systemd 常驻（直接用证书的写法；路径按实际情况改）：

   ```ini
   # /etc/systemd/system/cuepad-relay.service
   [Unit]
   Description=CuePad relay
   After=network-online.target

   [Service]
   WorkingDirectory=/opt/cuepad-relay
   Environment=PORT=443 CERT=/etc/letsencrypt/live/relay.example.com/fullchain.pem KEY=/etc/letsencrypt/live/relay.example.com/privkey.pem
   ExecStart=/usr/local/bin/bun server.ts
   Restart=always

   [Install]
   WantedBy=multi-user.target
   ```

   然后执行 `systemctl enable --now cuepad-relay`。证书续期以后要 `systemctl restart cuepad-relay`，Bun 才会读到新证书。
5. 检查：`curl https://relay.example.com/health` 应该返回 `ok`。
6. 把主机名填进 `apple/App/Config/Signing.xcconfig` 的 `CUEPAD_RELAY_HOST`（端口不是 443 时写成 `主机:端口`），再重新编译 App。
7. 你自己的 iCloud 容器里要有记录类型 `relaySecrets`，按 [docs/release.md](../docs/release.md)「CloudKit 数据结构」导入 `apple/CloudKit/cuepad.ckdb`。

## 用量

- 每台设备一条连接：Mac 在 App 运行期间一直连着，手机只在前台时连。连着时每 10 秒发一次心跳；中转 20 秒没收到任何东西就断开那条连接，不留死连接。
- 一个 1 核 1 GB 的进程能扛几千条连接。每千个活跃用户每月大约 60 GB 流量，主要是心跳。
