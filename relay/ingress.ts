import { isIP, SocketAddress } from "node:net";

const REQUESTS_PER_SECOND = 10;
const BURST = 60;
const MAX_SOURCES = 16_384;
const INTERVAL_MS = 1000 / REQUESTS_PER_SECOND;
const REFILL_MS = BURST * INTERVAL_MS;
const LOOPBACK = new Set(["127.0.0.1", "::1"]);

type Bucket = { source: string; ready: number; expires: number; previous?: Bucket; following?: Bucket };

function address(value: string): string | undefined {
  const family = isIP(value);
  if (!family) return;
  const canonical = SocketAddress.parse(family === 6 ? `[${value}]:0` : `${value}:0`)?.address;
  return canonical?.startsWith("::ffff:") && isIP(canonical.slice(7)) === 4 ? canonical.slice(7) : canonical;
}

function limited(milliseconds: number): Response {
  return Response.json({ reason: "RateLimited" }, {
    status: 429,
    headers: { "retry-after": String(Math.max(1, Math.ceil(milliseconds / 1000))), "cache-control": "no-store" },
  });
}

// 单进程、单入口的令牌桶：ready 是已用预算补满的时刻。按最后一次获准请求排序，
// 固定回收时长保证过期顺序相同；链表避免 Map 起始迭代器反复跳过已删除项。
// 每次只收一个过期项，满表拒绝新来源，不驱逐仍欠预算的来源。
export class Ingress {
  private readonly proxy = process.env.TRUST_PROXY === "loopback";
  private readonly sources = new Map<string, Bucket>();
  private first?: Bucket;
  private last?: Bucket;

  constructor() {
    if (process.env.TRUST_PROXY !== undefined && (!this.proxy
      || !LOOPBACK.has(address(process.env.HOST ?? "") ?? "") || process.env.CERT !== undefined)) {
      throw new Error("TRUST_PROXY requires loopback, an explicit loopback HOST and no Bun TLS");
    }
  }

  admit(req: Request, peer: string | undefined): Response | { secure: boolean } {
    let source = address(peer ?? "");
    let secure = new URL(req.url).protocol === "https:";
    if (this.proxy) {
      const forwarded = req.headers.get("x-forwarded-for");
      const protocol = req.headers.get("x-forwarded-proto");
      if (!LOOPBACK.has(source ?? "") || !forwarded || !(source = address(forwarded))
        || (protocol !== "https" && protocol !== "http")) {
        return Response.json({ reason: "InvalidProxyHeaders" }, { status: 400, headers: { "cache-control": "no-store" } });
      }
      secure = protocol === "https";
    }
    if (!source) return Response.json({ reason: "InvalidSource" }, { status: 400, headers: { "cache-control": "no-store" } });

    const now = performance.now();
    if (this.first && this.first.expires <= now) this.remove(this.first);
    const bucket = this.sources.get(source);
    if (!bucket && this.sources.size >= MAX_SOURCES) return limited(this.first!.expires - now);
    const ready = Math.max(now, bucket?.ready ?? now) + INTERVAL_MS;
    if (ready > now + REFILL_MS) return limited(ready - now - REFILL_MS);
    if (bucket) this.remove(bucket);
    const added = { source, ready, expires: now + REFILL_MS, previous: this.last };
    if (this.last) this.last.following = added;
    else this.first = added;
    this.last = added;
    this.sources.set(source, added);
    return { secure };
  }

  private remove(bucket: Bucket): void {
    if (bucket.previous) bucket.previous.following = bucket.following;
    else this.first = bucket.following;
    if (bucket.following) bucket.following.previous = bucket.previous;
    else this.last = bucket.previous;
    this.sources.delete(bucket.source);
  }
}
