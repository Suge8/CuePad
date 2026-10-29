// 一进程只服务一个 topic / 环境。连接与签名只在内存复用；不排队、不重试、不记录令牌或内容。
import { createHash, createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { connect, constants, sensitiveHeaders, type ClientHttp2Session, type ClientHttp2Stream } from "node:http2";

const REQUEST_TIMEOUT_MS = 10_000;
const MAX_IN_FLIGHT = 32;
const JWT_LIFETIME_S = 50 * 60;
const MAX_RESPONSE_BYTES = 4096;

type Environment = "production" | "development";
type Configuration = { key: KeyObject; keyID: string; teamID: string; topic: string; environment: Environment };
export type Push = { token: string; priority: 5 | 10; expiration: number; body: string };
export type Result = { status: number; reason?: string; apnsStatus?: number };

function configuration(): Configuration | undefined {
  const names = ["APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_ENVIRONMENT"];
  if (names.every(name => process.env[name] === undefined)) return;
  if (names.some(name => !process.env[name])) throw new Error("APNs configuration must include all five APNS_* values");
  const { APNS_KEY_FILE, APNS_KEY_ID: keyID, APNS_TEAM_ID: teamID, APNS_TOPIC: topic, APNS_ENVIRONMENT: environment } = process.env;
  if (!/^[A-Z0-9]{10}$/.test(keyID!) || !/^[A-Z0-9]{10}$/.test(teamID!)
    || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\.push-type\.liveactivity$/.test(topic!) || topic!.length > 255
    || (environment !== "production" && environment !== "development")) throw new Error("Invalid APNs configuration");
  let key: KeyObject;
  try {
    key = createPrivateKey(readFileSync(APNS_KEY_FILE!));
  } catch {
    throw new Error("Cannot read APNs private key");
  }
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") throw new Error("APNs requires a P-256 private key");
  return { key, keyID: keyID!, teamID: teamID!, topic: topic!, environment };
}

function reasonFrom(body: string): string | undefined {
  try {
    const reason = JSON.parse(body).reason;
    if (typeof reason === "string" && /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(reason)) return reason;
  } catch { /* 上游非 JSON 错误不回显，避免泄露请求内容。 */ }
}

function response(status: number, body: string): Result {
  if (status === 200 && body === "") return { status: 204 };
  const reason = reasonFrom(body) ?? "APNsInvalidResponse";
  const invalidToken = (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"))
    || (status === 410 && reason === "Unregistered");
  return { status: invalidToken ? 410 : status === 429 || status === 503 ? status : 502, reason, apnsStatus: status };
}

export class APNs {
  private session?: ClientHttp2Session;
  private authenticated = false;
  private pending = new Map<ClientHttp2Stream, (result: Result) => void>();
  private jwt = "";
  private issuedAt = 0;

  constructor(private readonly config: Configuration) {
    this.authorization();
  }

  get environment(): Environment { return this.config.environment; }

  private authorization(): string {
    const now = Math.floor(Date.now() / 1000);
    if (!this.jwt || now - this.issuedAt >= JWT_LIFETIME_S) {
      const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
      const unsigned = `${encode({ alg: "ES256", kid: this.config.keyID })}.${encode({ iss: this.config.teamID, iat: now })}`;
      const signature = sign("sha256", Buffer.from(unsigned), { key: this.config.key, dsaEncoding: "ieee-p1363" });
      this.jwt = `${unsigned}.${signature.toString("base64url")}`;
      this.issuedAt = now;
    }
    return `bearer ${this.jwt}`;
  }

  private connection(): ClientHttp2Session {
    if (this.session) return this.session;
    const host = this.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const session = connect(`https://${host}`, { minVersion: "TLSv1.2" });
    this.session = session;
    this.authenticated = false;
    session.on("error", () => this.disconnect(session, "APNsConnectionError"));
    session.on("close", () => this.disconnect(session, "APNsDisconnected"));
    session.on("goaway", (_code, _lastID, data) => this.disconnect(session, reasonFrom(data.toString()) ?? "APNsGoAway"));
    return session;
  }

  private disconnect(session: ClientHttp2Session, reason: string): void {
    if (this.session !== session) return;
    this.session = undefined;
    for (const finish of this.pending.values()) finish({ status: 502, reason });
    session.destroy();
  }

  close(): void {
    if (this.session) this.disconnect(this.session, "APNsStopped");
  }

  async send(push: Push): Promise<Result> {
    let session: ClientHttp2Session;
    let authorization: string;
    try {
      session = this.connection();
      authorization = this.authorization();
    } catch {
      return { status: 503, reason: "APNsUnavailable" };
    }
    // APNs 在第一份有效认证前只准一个 stream；也服从服务端随时调整的 SETTINGS。
    const limit = Math.min(MAX_IN_FLIGHT, this.authenticated ? MAX_IN_FLIGHT : 1, session.remoteSettings.maxConcurrentStreams ?? 1);
    if (this.pending.size >= limit) return { status: 503, reason: "APNsBusy" };
    return new Promise(resolve => {
      let stream: ClientHttp2Stream;
      try {
        stream = session.request({
          ":method": "POST",
          ":path": `/3/device/${push.token}`,
          authorization,
          "apns-topic": this.config.topic,
          "apns-push-type": "liveactivity",
          "apns-priority": String(push.priority),
          "apns-expiration": String(push.expiration),
          "apns-collapse-id": createHash("sha256").update(push.token).digest("hex"),
          "content-type": "application/json",
          [sensitiveHeaders]: [":path", "authorization"],
        });
      } catch {
        this.disconnect(session, "APNsConnectionError");
        resolve({ status: 502, reason: "APNsConnectionError" });
        return;
      }
      const finish = (result: Result) => {
        if (!this.pending.delete(stream)) return;
        clearTimeout(timer);
        resolve(result);
        stream.close(stream.readableEnded ? constants.NGHTTP2_NO_ERROR : constants.NGHTTP2_CANCEL);
      };
      const timer = setTimeout(() => {
        finish({ status: 504, reason: "APNsTimeout" });
        this.disconnect(session, "APNsConnectionError");
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(stream, finish);
      let status = 0;
      let size = 0;
      const chunks: Buffer[] = [];
      stream.on("response", headers => { status = Number(headers[":status"]); });
      stream.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) finish({ status: 502, reason: "APNsInvalidResponse" });
        else chunks.push(chunk);
      });
      stream.on("end", () => {
        // HTTP/2 的 RST_STREAM 也会触发 end；收到 200 头不等于完整成功响应。
        if (stream.destroyed || stream.aborted || stream.rstCode !== constants.NGHTTP2_NO_ERROR) {
          finish({ status: 502, reason: "APNsStreamError" });
          return;
        }
        const result = response(status, Buffer.concat(chunks).toString());
        if (result.status === 204 && this.pending.has(stream) && this.session === session) this.authenticated = true;
        finish(result);
      });
      stream.on("error", () => finish({ status: 502, reason: "APNsStreamError" }));
      stream.on("close", () => finish({ status: 502, reason: "APNsDisconnected" }));
      stream.end(push.body);
    });
  }
}

export function configuredAPNs(): APNs | undefined {
  const config = configuration();
  return config ? new APNs(config) : undefined;
}
