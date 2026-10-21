import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { reason } from "./text.ts";

/** 查订阅额度的单个请求最多等这么久（接口实测约 150ms；VPN 断了就是查不到，CuePad 保留上次的值） */
const QUOTA_TIMEOUT_MS = 3_000;
const FIVE_HOURS = 5 * 3_600;
const WEEK = 7 * 86_400;
/** 订阅额度：Pi 用 OAuth 订阅登录的提供方（其余是按量的 API 密钥，没有额度窗口）。查用量的接口只读、不耗额度。 */
const QUOTA_PROVIDERS: Record<string, { url: string; headers: (token: string) => Record<string, string>; parse: (body: unknown) => QuotaWindow[] }> = {
	anthropic: { url: "https://api.anthropic.com/api/oauth/usage", headers: () => ({ "anthropic-beta": "oauth-2025-04-20" }), parse: claudeUsage },
	"openai-codex": {
		url: "https://chatgpt.com/backend-api/wham/usage", headers: (token) => ({ "ChatGPT-Account-Id": codexAccount(token) }),
		parse: (body) => codexWindows(record(record(body).rate_limit), "primary_window", "secondary_window", "limit_window_seconds", 1),
	},
};

/** 一个额度窗口：长度（秒）、已用比例（0..1）、重置时刻（Unix 秒）、只算某个模型时的模型显示名；
 * `binding` 是提供方说此刻卡着的就是它（Claude 响应头的 representative-claim），提供方没说的不带 */
type QuotaWindow = { seconds: number; used: number; resetsAt: number; model: string | null; binding?: true };
/** 一个提供方的一次观测；`complete` 是全部窗口（查用量接口得到的），回复里带回的只有一部分 */
export type Quota = { provider: string; windows: QuotaWindow[]; complete: boolean };

export function record(value: unknown): Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function finite(value: unknown): number | null {
	const number = typeof value === "string" ? Number(value) : value;
	return typeof number === "number" && Number.isFinite(number) ? number : null;
}

function quotaWindow(seconds: number | null, used: number | null, resetsAt: number | null, model: string | null = null): QuotaWindow[] {
	return seconds !== null && seconds > 0 && used !== null && used >= 0 && resetsAt !== null ? [{ seconds, used, resetsAt, model }] : [];
}

/** Claude 响应头里的窗口：头里的名字、representative-claim 里的名字、长度。 */
const CLAUDE_HEADER_WINDOWS = [
	{ header: "5h", claim: "five_hour", seconds: FIVE_HOURS },
	{ header: "7d", claim: "seven_day", seconds: WEEK },
] as const;

/** Claude 每次回复的响应头：5 小时与本周两个窗口（比例 0..1、重置 Unix 秒），没有按模型的周额度；representative-claim 指的那个标为卡着的。
 * API 密钥的回复没有这些头。 */
export function claudeHeaderWindows(headers: Record<string, string>): QuotaWindow[] {
	const header = (window: string, field: string) => finite(headers[`anthropic-ratelimit-unified-${window}-${field}`]);
	const claim = headers["anthropic-ratelimit-unified-representative-claim"];
	return CLAUDE_HEADER_WINDOWS.flatMap((w) =>
		quotaWindow(w.seconds, header(w.header, "utilization"), header(w.header, "reset"))
			.map((window): QuotaWindow => w.claim === claim ? { ...window, binding: true } : window));
}

/** Claude 的用量接口：`limits[]` 里的 5 小时、本周与按模型的周额度（百分比、ISO 时刻）。 */
function claudeUsage(body: unknown): QuotaWindow[] {
	const limits = record(body).limits;
	if (!Array.isArray(limits)) return [];
	return limits.flatMap((value) => {
		const entry = record(value);
		const percent = finite(entry.percent);
		const used = percent === null ? null : percent / 100;
		const reset = typeof entry.resets_at === "string" ? Date.parse(entry.resets_at) / 1000 : null;
		const resetsAt = reset !== null && Number.isFinite(reset) ? reset : null;
		if (entry.kind === "session") return quotaWindow(FIVE_HOURS, used, resetsAt);
		if (entry.kind === "weekly_all") return quotaWindow(WEEK, used, resetsAt);
		const model = record(record(entry.scope).model).display_name;
		if (entry.kind === "weekly_scoped" && typeof model === "string" && model) return quotaWindow(WEEK, used, resetsAt, model);
		return [];
	});
}

/** Codex 的窗口：流里的 `codex.rate_limits`（`primary`/`secondary`，长度按分钟）与用量接口（`primary_window`/`secondary_window`，长度按秒）同一形状。 */
export function codexWindows(limits: Record<string, unknown>, primary: string, secondary: string, length: string, unit: number): QuotaWindow[] {
	return [limits[primary], limits[secondary]].flatMap((value) => {
		const entry = record(value);
		const span = finite(entry[length]);
		const percent = finite(entry.used_percent);
		return quotaWindow(span === null ? null : span * unit, percent === null ? null : percent / 100, finite(entry.reset_at));
	});
}

/** Codex 的令牌里带着账号 id，用量接口要它。 */
function codexAccount(token: string): string {
	const claims = record(JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8")));
	const id = record(claims["https://api.openai.com/auth"]).chatgpt_account_id;
	if (typeof id !== "string" || !id) throw new Error("codex token has no account id");
	return id;
}

/** 按需查订阅额度（CuePad 的 `quota` 命令）；查到的每家交给 `report` 报出去。 */
export class QuotaFetcher {
	/** 正在查的额度：几个客户端同时要时共用这一次 */
	private inFlight: Promise<string[]> | null = null;

	private readonly ctx: ExtensionContext;
	private readonly report: (quota: Quota) => void;

	constructor(ctx: ExtensionContext, report: (quota: Quota) => void) {
		this.ctx = ctx;
		this.report = report;
	}

	/** 查一次所有订阅的额度，返回各家的失败原因（全部查到或没有订阅为空）。查到的那几家已经报出去了。 */
	fetchAll(): Promise<string[]> {
		this.inFlight ??= Promise.allSettled(Object.keys(QUOTA_PROVIDERS).map((provider) => this.fetch(provider)))
			.then((results) => results.flatMap((r) => r.status === "rejected" ? [reason(r.reason)] : []))
			.finally(() => { this.inFlight = null; });
		return this.inFlight;
	}

	/** 查一个提供方的用量：没用 OAuth 订阅登录的（API 密钥、没登录）跳过，返回 false；查到就报出去。令牌经 Pi 取（会自动刷新）。 */
	private async fetch(provider: string): Promise<boolean> {
		const source = QUOTA_PROVIDERS[provider];
		const registry = this.ctx.modelRegistry;
		const model = registry.getAll().find((m) => m.provider === provider);
		if (!model || !registry.isUsingOAuth(model)) return false;
		const token = (await registry.getProviderAuth(provider))?.auth.apiKey;
		if (!token) throw new Error(`${provider}: no token`);
		const response = await fetch(source.url, {
			headers: { Authorization: `Bearer ${token}`, Accept: "application/json", ...source.headers(token) },
			signal: AbortSignal.timeout(QUOTA_TIMEOUT_MS),
		});
		if (!response.ok) throw new Error(`${provider}: HTTP ${response.status}`);
		const windows = source.parse(await response.json());
		if (windows.length === 0) throw new Error(`${provider}: unrecognized usage format`);
		this.report({ provider, windows, complete: true });
		return true;
	}
}
