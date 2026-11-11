// CuePad 门铃中转：同一个人的设备进同一个房间；一台的改动被 iCloud 收下后按一下门铃，中转转给房间里的其它设备，它们自己去 iCloud 拉。
// 门铃帧不带内容。通话另在同一连接上转发定向加密信令（voice.ts），声音不经过中转；实时活动走 /v1/activity（activity.ts）。
// 两种转发都不留存正文。房间号是设备由 iCloud 里的密钥派生的 Ed25519 公钥；入房要对中转给的随机数签名，
// 没有密钥的人进不了房间，也就按不了这个房间的门铃。
//
// 协议（文本帧，JSON）：
//   连 wss://<主机>/v1/<房间号：公钥 32 字节的 base64url，不补等号>
//   中转 → {"t":"challenge","n":<随机数 base64url>}
//   设备 → {"t":"auth","s":<对 "cuepad-relay-v1\n<房间号>\n<随机数>" 的签名 base64url>}，AUTH_TIMEOUT 内不签或签错即断
//   中转 → {"t":"ready","voiceVersion":1}；旧门铃客户端可忽略扩展能力
//   设备 → {"t":"ring"}，中转转给同房间其它连接 {"t":"ring"}
//   通话设备在 ready 后用 {"t":"voice","body":…} 登记、解析目标租约或发信令；v1 形状与原生 VoiceSignaling.swift 对应。
//   登记还须签名绑定 room/challenge/device/本机新 lease；同设备新连接替换旧租约，观察者收到 departed，旧连接以 4409 关闭。
// 心跳用 WebSocket 协议层的 ping：设备每 10 秒一次；IDLE_TIMEOUT_S 内什么都没收到的连接（设备睡了、断网、被挂起）由中转断开，不留死连接。
//
// 环境变量：PORT（默认 8080）；HOST 是监听地址（默认所有地址，放在反向代理后面时给 127.0.0.1）；
// CERT、KEY 是 PEM 证书与私钥路径，给了就直接提供 TLS；回环 Caddy 代理另设 TRUST_PROXY=loopback（来源与限频在 ingress.ts）。
import type { ServerWebSocket } from "bun";
import { configuredAPNs } from "./apns";
import { activity, MAX_REQUEST_BYTES } from "./activity";
import { verifySignature } from "./auth";
import { Ingress } from "./ingress";
import { MAX_VOICE_WIRE_BYTES, VoiceRouter, VOICE_VERSION, type Peer } from "./voice";

const ingress = new Ingress();
const apns = configuredAPNs();
const PROTOCOL = "cuepad-relay-v1";
const AUTH_TIMEOUT_MS = 10_000;
const IDLE_TIMEOUT_S = 20;
const ROOM = /^\/v1\/([A-Za-z0-9_-]{43})$/;

const MAX_BELL_BYTES = 1024;
let connectionOrder = 0;
const voice = new VoiceRouter(closePeer);
const base64url = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64url");

function closePeer(socket: ServerWebSocket<Peer>, code: number, reason: string): void {
  socket.data.phase = "closed";
  clearTimeout(socket.data.timer);
  voice.remove(socket, code === 4409 ? "replaced" : "disconnected");
  socket.close(code, reason);
}

async function authenticate(socket: ServerWebSocket<Peer>, signature: unknown): Promise<void> {
  if (typeof signature !== "string" || !/^[A-Za-z0-9_-]{86}$/.test(signature)) return closePeer(socket, 4401, "bad signature");
  socket.data.phase = "authenticating";
  const valid = await verifySignature(socket.data.room, `${PROTOCOL}\n${socket.data.room}\n${socket.data.nonce}`, Buffer.from(signature, "base64url"));
  if (socket.data.phase !== "authenticating") return;
  if (!valid) return closePeer(socket, 4401, "bad signature");
  clearTimeout(socket.data.timer);
  socket.data.phase = "ready";
  socket.subscribe(socket.data.room);
  socket.send(JSON.stringify({ t: "ready", voiceVersion: VOICE_VERSION }));
}

const server = Bun.serve<Peer, never>({
  port: Number(process.env.PORT ?? 8080),
  hostname: process.env.HOST,
  maxRequestBodySize: MAX_REQUEST_BYTES,
  tls: process.env.CERT ? { cert: Bun.file(process.env.CERT), key: Bun.file(process.env.KEY!) } : undefined,
  fetch(req, server) {
    const path = new URL(req.url).pathname;
    if (path === "/health") return new Response("ok");
    if (path === "/v1/activity/health") {
      const headers = { "cache-control": "no-store", allow: "GET" };
      return new Response(null, { status: req.method === "GET" ? (apns ? 204 : 503) : 405, headers });
    }
    const room = path.match(ROOM)?.[1];
    if (path === "/v1/activity" || room) {
      const admitted = ingress.admit(req, server.requestIP(req)?.address);
      if (admitted instanceof Response) return admitted;
      if (path === "/v1/activity") return activity(req, apns, admitted.secure);
      if (room && server.upgrade(req, {
        data: { room, nonce: base64url(crypto.getRandomValues(new Uint8Array(32))), phase: "challenge", order: ++connectionOrder },
      })) return;
    }
    return new Response("not found", { status: 404 });
  },
  websocket: {
    idleTimeout: IDLE_TIMEOUT_S,
    maxPayloadLength: MAX_VOICE_WIRE_BYTES,
    backpressureLimit: MAX_VOICE_WIRE_BYTES * 2,
    closeOnBackpressureLimit: true,
    open(ws) {
      ws.send(JSON.stringify({ t: "challenge", n: ws.data.nonce }));
      ws.data.timer = setTimeout(() => closePeer(ws, 4401, "auth timeout"), AUTH_TIMEOUT_MS);
    },
    async message(ws, raw) {
      if (ws.data.phase === "closed") return;
      const text = String(raw);
      const bytes = Buffer.byteLength(text);
      if ((ws.data.phase === "challenge" || ws.data.phase === "authenticating") && bytes > MAX_BELL_BYTES) {
        return closePeer(ws, 4401, "auth frame too large");
      }
      let message: Record<string, unknown>;
      try {
        const parsed: unknown = JSON.parse(text);
        if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("not an object");
        message = parsed as Record<string, unknown>;
      } catch {
        return closePeer(ws, 4400, "bad frame");
      }
      if (ws.data.phase === "challenge") {
        if (message.t !== "auth") return closePeer(ws, 4401, "auth required");
        return authenticate(ws, message.s);
      }
      if (ws.data.phase === "authenticating") return closePeer(ws, 4401, "auth in progress");
      if (message.t === "voice" && Object.keys(message).length === 2) return voice.receive(ws, message.body);
      if (message.t !== "ring" || Object.keys(message).length !== 1 || bytes > MAX_BELL_BYTES) {
        return closePeer(ws, 4400, "bad frame");
      }
      ws.publish(ws.data.room, '{"t":"ring"}'); // publish 不发回给自己
    },
    close(ws) {
      ws.data.phase = "closed";
      clearTimeout(ws.data.timer);
      voice.remove(ws, "disconnected");
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
