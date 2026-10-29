import { type APNs, type Push, type Result } from "./apns";

export const MAX_REQUEST_BYTES = 16 * 1024;
const MAX_PAYLOAD_BYTES = 4096;
const MAX_TOKEN_HEX_LENGTH = 1024;

const object = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const only = (value: Record<string, unknown>, keys: string[]) => Object.keys(value).every(key => keys.includes(key));
const seconds = (value: unknown) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

function parse(value: unknown, environment: string): Push | Result {
  if (!object(value) || !only(value, ["token", "environment", "priority", "payload"])
    || typeof value.token !== "string" || !/^(?:[a-fA-F0-9]{2})+$/.test(value.token) || value.token.length > MAX_TOKEN_HEX_LENGTH
    || (value.environment !== "production" && value.environment !== "development")
    || (value.priority !== 5 && value.priority !== 10)
    || !object(value.payload) || !only(value.payload, ["aps"]) || !object(value.payload.aps)) return { status: 400, reason: "InvalidActivity" };
  const aps = value.payload.aps;
  if (!only(aps, ["timestamp", "event", "content-state", "stale-date", "dismissal-date"])
    || !seconds(aps.timestamp) || (aps.event !== "update" && aps.event !== "end") || !object(aps["content-state"])
    || ("stale-date" in aps && !seconds(aps["stale-date"]))
    || ("dismissal-date" in aps && !seconds(aps["dismissal-date"]))) return { status: 400, reason: "InvalidActivity" };
  if (value.environment !== environment) return { status: 400, reason: "EnvironmentMismatch" };
  const body = JSON.stringify(value.payload);
  if (Buffer.byteLength(body) > MAX_PAYLOAD_BYTES) return { status: 413, reason: "PayloadTooLarge" };
  return { token: value.token, priority: value.priority, body };
}

function reply(result: Result): Response {
  const headers = { "cache-control": "no-store" };
  if (result.status === 204) return new Response(null, { status: 204, headers });
  const { status, ...body } = result;
  return Response.json(body, { status, headers });
}

export async function activity(req: Request, apns: APNs | undefined, secure: boolean): Promise<Response> {
  if (!secure) return reply({ status: 426, reason: "HTTPSRequired" });
  if (req.method !== "POST") return Response.json({ reason: "MethodNotAllowed" }, { status: 405, headers: { allow: "POST", "cache-control": "no-store" } });
  if (new URL(req.url).search) return reply({ status: 400, reason: "QueryNotAllowed" });
  if (!apns) return reply({ status: 503, reason: "ActivityUnavailable" });
  if (req.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json"
    || (req.headers.has("content-encoding") && req.headers.get("content-encoding") !== "identity")) return reply({ status: 415, reason: "JSONRequired" });
  if (Number(req.headers.get("content-length")) > MAX_REQUEST_BYTES) return reply({ status: 413, reason: "RequestTooLarge" });
  if (!req.body) return reply({ status: 400, reason: "InvalidJSON" });
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  let value: unknown;
  try {
    for (;;) {
      const { done, value: chunk } = await reader.read();
      if (done) break;
      size += chunk.length;
      if (size > MAX_REQUEST_BYTES) {
        await reader.cancel();
        return reply({ status: 413, reason: "RequestTooLarge" });
      }
      chunks.push(chunk);
    }
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)));
  } catch {
    return reply({ status: 400, reason: "InvalidJSON" });
  } finally {
    reader.releaseLock();
  }
  const push = parse(value, apns.environment);
  return reply("status" in push ? push : await apns.send(push));
}
