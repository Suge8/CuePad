// CuePad 门铃中转：同一个人的设备进同一个房间；一台的改动被 iCloud 收下后按一下门铃，中转转给房间里的其它设备，它们自己去 iCloud 拉。
// 中转不存任何东西、不看内容，门铃不带内容。房间号是设备由 iCloud 里的密钥派生的 Ed25519 公钥；入房要对中转给的随机数签名，
// 没有密钥的人进不了房间，也就按不了这个房间的门铃。
//
// 协议（文本帧，JSON）：
//   连 wss://<主机>/v1/<房间号：公钥 32 字节的 base64url，不补等号>
//   中转 → {"t":"challenge","n":<随机数 base64url>}
//   设备 → {"t":"auth","s":<对 "cuepad-relay-v1\n<房间号>\n<随机数>" 的签名 base64url>}，AUTH_TIMEOUT 内不签或签错即断
//   中转 → {"t":"ready"}
//   设备 → {"t":"ring"}，中转转给同房间其它连接 {"t":"ring"}
// 心跳用 WebSocket 协议层的 ping：设备每 10 秒一次；IDLE_TIMEOUT_S 内什么都没收到的连接（设备睡了、断网、被挂起）由中转断开，不留死连接。
//
// 环境变量：PORT（默认 8080）；HOST 是监听地址（默认所有地址，放在反向代理后面时给 127.0.0.1）；
// CERT、KEY 是 PEM 证书与私钥路径，给了就直接提供 TLS，不给就是明文（放在 Caddy 等反向代理后面）。
import { configuredAPNs } from "./apns";
import { activity, MAX_REQUEST_BYTES } from "./activity";

const apns = configuredAPNs();
const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);
const PROTOCOL = "cuepad-relay-v1";
const AUTH_TIMEOUT_MS = 10_000;
const IDLE_TIMEOUT_S = 20;
const ROOM = /^\/v1\/([A-Za-z0-9_-]{43})$/;

type Peer = { room: string; nonce: string; authed: boolean; timer?: Timer };

const base64url = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64url");

async function verified(room: string, nonce: string, signature: unknown): Promise<boolean> {
  if (typeof signature !== "string") return false;
  try {
    const key = await crypto.subtle.importKey("raw", Buffer.from(room, "base64url"), { name: "Ed25519" }, false, ["verify"]);
    const message = new TextEncoder().encode(`${PROTOCOL}\n${room}\n${nonce}`);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, Buffer.from(signature, "base64url"), message);
  } catch {
    return false;
  }
}

const server = Bun.serve<Peer, never>({
  port: Number(process.env.PORT ?? 8080),
  hostname: process.env.HOST,
  maxRequestBodySize: MAX_REQUEST_BYTES,
  tls: process.env.CERT ? { cert: Bun.file(process.env.CERT), key: Bun.file(process.env.KEY!) } : undefined,
  fetch(req, server) {
    const path = new URL(req.url).pathname;
    if (path === "/health") return new Response("ok");
    if (path === "/v1/activity") {
      // 只信任显式绑定回环地址、由本机 TLS 代理覆盖的协议头，不信任公网来客自报 HTTPS。
      const secure = new URL(req.url).protocol === "https:" || (LOOPBACK.has(process.env.HOST ?? "")
        && LOOPBACK.has(server.requestIP(req)?.address ?? "") && req.headers.get("x-forwarded-proto") === "https");
      return activity(req, apns, secure);
    }
    const room = path.match(ROOM)?.[1];
    if (room && server.upgrade(req, { data: { room, nonce: base64url(crypto.getRandomValues(new Uint8Array(32))), authed: false } })) return;
    return new Response("not found", { status: 404 });
  },
  websocket: {
    idleTimeout: IDLE_TIMEOUT_S,
    maxPayloadLength: 1024,
    open(ws) {
      ws.send(JSON.stringify({ t: "challenge", n: ws.data.nonce }));
      ws.data.timer = setTimeout(() => ws.close(4401, "auth timeout"), AUTH_TIMEOUT_MS);
    },
    async message(ws, raw) {
      let message: { t?: unknown; s?: unknown };
      try {
        message = JSON.parse(String(raw));
      } catch {
        return ws.close(4400, "bad frame");
      }
      if (!ws.data.authed) {
        if (message.t !== "auth" || !(await verified(ws.data.room, ws.data.nonce, message.s))) return ws.close(4401, "bad signature");
        clearTimeout(ws.data.timer);
        ws.data.authed = true;
        ws.subscribe(ws.data.room);
        ws.send(JSON.stringify({ t: "ready" }));
        return;
      }
      if (message.t !== "ring") return ws.close(4400, "bad frame");
      ws.publish(ws.data.room, '{"t":"ring"}'); // publish 不发回给自己
    },
    close(ws) {
      clearTimeout(ws.data.timer);
    },
  },
});

console.log(`cuepad relay listening on ${server.port}${process.env.CERT ? " (tls)" : ""}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    apns?.close();
    server.stop(true);
  });
}
