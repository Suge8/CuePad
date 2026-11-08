import type { ServerWebSocket } from "bun";
import { verifySignature } from "./auth";

// 与原生 VoiceSignalFormat 的 v1 契约对应；正文仅两端解密，这里不解释业务命令或保存信令历史。
export const VOICE_VERSION = 1;
export const MAX_VOICE_WIRE_BYTES = 64 * 1024;
const MAX_DEVICE_BYTES = 128;
const MAX_SEALED_BYTES = 32 * 1024 + 28; // AES.GCM 的 nonce 与 tag
const LIFETIME_MS = 30_000;
const REGISTRATION_CONTEXT = "cuepad-relay-voice-v1";
const REGISTRATION_TIMEOUT_MS = 10_000;
const REPLACED = 4409;
// 约束同一房间的租约观察图；仅数当前连接，不数 iCloud 中曾登记的设备。
const MAX_VOICE_PEERS = 64;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Endpoint = { device: { rawValue: string }; lease: string };
type Header = {
  version: number; sender: Endpoint; recipient: Endpoint; session: { rawValue: string };
  sequence: number; expiresAtMilliseconds: number;
};
type Packet = { header: Header; sealed: string };
type Departure = "disconnected" | "replaced";
type Rejection = "expired" | "leaseMismatch" | "unavailable" | "tooLarge" | "invalid";
type Socket = ServerWebSocket<Peer>;
type Member = { socket: Socket; endpoint: Endpoint; watching: Set<Member>; watchers: Set<Member> };
export type Peer = {
  room: string; nonce: string; order: number;
  phase: "challenge" | "authenticating" | "ready" | "registering" | "registered" | "closed";
  timer?: Timer; voice?: Member;
};

function shape(value: unknown, keys: string[]): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function device(value: unknown): value is Endpoint["device"] {
  return shape(value, ["rawValue"]) && typeof value.rawValue === "string" && value.rawValue.length > 0
    && Buffer.byteLength(value.rawValue) <= MAX_DEVICE_BYTES;
}

function uuid(value: unknown): value is string { return typeof value === "string" && UUID.test(value); }
function endpoint(value: unknown): value is Endpoint {
  return shape(value, ["device", "lease"]) && device(value.device) && uuid(value.lease);
}
function equal(a: Endpoint, b: Endpoint): boolean {
  return a.device.rawValue === b.device.rawValue && a.lease.toUpperCase() === b.lease.toUpperCase();
}
function header(value: unknown): value is Header {
  return shape(value, ["version", "sender", "recipient", "session", "sequence", "expiresAtMilliseconds"])
    && value.version === VOICE_VERSION && endpoint(value.sender) && endpoint(value.recipient)
    && shape(value.session, ["rawValue"]) && uuid(value.session.rawValue)
    && typeof value.sequence === "number" && Number.isInteger(value.sequence) && value.sequence > 0 && value.sequence <= 0xffffffff
    && typeof value.expiresAtMilliseconds === "number" && Number.isSafeInteger(value.expiresAtMilliseconds);
}
function base64(value: unknown): Buffer | undefined {
  if (typeof value !== "string" || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return;
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64") === value) return bytes;
}

export class VoiceRouter {
  private readonly rooms = new Map<string, Map<string, Member>>();

  constructor(private readonly close: (socket: Socket, code: number, reason: string) => void) {}

  async receive(socket: Socket, body: unknown): Promise<void> {
    if (shape(body, ["register"])) {
      await this.register(socket, body.register);
      return;
    }
    const source = this.current(socket);
    if (!source) return this.close(socket, 4400, "voice registration required");
    if (shape(body, ["resolve"]) && shape(body.resolve, ["request", "device"])
      && uuid(body.resolve.request) && device(body.resolve.device)) {
      this.resolve(source, body.resolve.request, body.resolve.device);
      return;
    }
    if (shape(body, ["signal"]) && shape(body.signal, ["packet"])
      && shape(body.signal.packet, ["header", "sealed"]) && header(body.signal.packet.header)) {
      const { header: route, sealed } = body.signal.packet;
      const bytes = base64(sealed);
      if (!bytes || bytes.length < 28) return this.reject(source, route, "invalid");
      if (bytes.length > MAX_SEALED_BYTES) return this.reject(source, route, "tooLarge");
      this.forward(source, { header: route, sealed: sealed as string });
      return;
    }
    this.close(socket, 4400, "bad voice frame");
  }

  remove(socket: Socket, reason: Departure): void {
    const member = socket.data.voice;
    socket.data.voice = undefined;
    if (!member) return;
    const room = this.rooms.get(socket.data.room);
    if (room?.get(member.endpoint.device.rawValue) === member) room.delete(member.endpoint.device.rawValue);
    if (room?.size === 0) this.rooms.delete(socket.data.room);
    // 先解开双向订阅，再通知；慢端发送失败会递归关连接，不能在回调中再次认领旧成员。
    for (const target of member.watching) target.watchers.delete(member);
    const observers = [...member.watchers];
    for (const observer of observers) observer.watching.delete(member);
    member.watching.clear();
    member.watchers.clear();
    for (const observer of observers) this.send(observer.socket, { departed: { endpoint: member.endpoint, reason } });
  }

  private async register(socket: Socket, value: unknown): Promise<void> {
    if (socket.data.phase !== "ready" || !shape(value, ["claim", "signature"])
      || !shape(value.claim, ["version", "room", "challenge", "device", "lease"])) {
      return this.close(socket, 4400, "bad voice registration");
    }
    const claim = value.claim;
    const signature = base64(value.signature);
    if (claim.version !== VOICE_VERSION || claim.room !== socket.data.room || claim.challenge !== socket.data.nonce
      || !device(claim.device) || !uuid(claim.lease) || !signature || signature.length !== 64) {
      return this.close(socket, 4401, "bad voice claim");
    }
    socket.data.phase = "registering";
    socket.data.timer = setTimeout(() => this.close(socket, 4401, "voice registration timeout"), REGISTRATION_TIMEOUT_MS);
    // 与 Swift sortedKeys + withoutEscapingSlashes 一致；包含本机新租约，不能由中转重放旧租约。
    const canonical = JSON.stringify({ challenge: claim.challenge, device: claim.device, lease: claim.lease, room: claim.room, version: claim.version });
    const valid = await verifySignature(socket.data.room, `${REGISTRATION_CONTEXT}\n${canonical}`, signature);
    if (socket.data.phase !== "registering") return;
    clearTimeout(socket.data.timer);
    if (!valid) return this.close(socket, 4401, "bad voice signature");
    const previous = this.rooms.get(socket.data.room)?.get(claim.device.rawValue);
    if (previous && (previous.socket.data.order > socket.data.order || previous.endpoint.lease.toUpperCase() === claim.lease.toUpperCase())) {
      return this.close(socket, REPLACED, "voice registration superseded");
    }
    if (!previous && (this.rooms.get(socket.data.room)?.size ?? 0) >= MAX_VOICE_PEERS) {
      return this.close(socket, 4408, "voice room full");
    }
    if (previous) this.close(previous.socket, REPLACED, "voice lease replaced");
    if (socket.data.phase !== "registering") return;
    const member: Member = {
      socket, endpoint: { device: claim.device, lease: claim.lease }, watching: new Set(), watchers: new Set(),
    };
    const room = this.rooms.get(socket.data.room) ?? new Map<string, Member>();
    room.set(claim.device.rawValue, member);
    this.rooms.set(socket.data.room, room);
    socket.data.voice = member;
    socket.data.phase = "registered";
    this.send(socket, { registered: { endpoint: member.endpoint } });
  }

  private current(socket: Socket): Member | undefined {
    const member = socket.data.voice;
    if (socket.data.phase === "registered" && socket.readyState === WebSocket.OPEN && member
      && this.rooms.get(socket.data.room)?.get(member.endpoint.device.rawValue) === member) return member;
  }

  private target(source: Member, name: string): Member | undefined {
    const target = this.rooms.get(source.socket.data.room)?.get(name);
    if (target && this.current(target.socket) === target) return target;
  }

  private resolve(source: Member, request: string, name: Endpoint["device"]): void {
    const target = this.target(source, name.rawValue);
    if (!target) return void this.send(source.socket, { unavailable: { request, device: name } });
    this.observe(source, target);
    this.send(source.socket, { resolved: { request, endpoint: target.endpoint } });
  }

  private forward(source: Member, packet: Packet): void {
    const { header: route } = packet;
    if (!equal(route.sender, source.endpoint)) return this.reject(source, route, "leaseMismatch");
    const now = Date.now();
    if (route.expiresAtMilliseconds <= now || route.expiresAtMilliseconds > now + LIFETIME_MS) {
      return this.reject(source, route, "expired");
    }
    const target = this.target(source, route.recipient.device.rawValue);
    if (!target) return this.reject(source, route, "unavailable");
    if (!equal(target.endpoint, route.recipient)) return this.reject(source, route, "leaseMismatch");
    // 只提交当前 socket，既不改投新租约也不确认远端收到；AEAD 与单调序号由收端验证后才推进。
    if (!this.send(target.socket, { signal: { packet } })) return this.reject(source, route, "unavailable");
    this.observe(source, target);
    this.observe(target, source);
  }

  private observe(observer: Member, target: Member): void {
    if (observer === target) return;
    observer.watching.add(target);
    target.watchers.add(observer);
  }

  private reject(source: Member, route: Header, reason: Rejection): void {
    this.send(source.socket, { rejected: { header: route, reason } });
  }

  private send(socket: Socket, body: object): boolean {
    if (!this.current(socket)) return false;
    const sent = socket.send(JSON.stringify({ t: "voice", body }));
    if (sent !== 0) return true; // -1 是此连接有界的 WebSocket 缓冲，并不是已送达。
    this.close(socket, 4410, "voice receiver unavailable");
    return false;
  }
}
