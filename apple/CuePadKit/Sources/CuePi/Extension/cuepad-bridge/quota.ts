import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { reason } from "./info.ts";
import { gatewayQuotas } from "./quota-gateway.ts";
import { account, unresolvedAccount, type Account, type Model } from "./account.ts";

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
export type QuotaWindow = { seconds: number; used: number; resetsAt: number; model: string | null; binding?: true };
/** 一个提供方的一次观测；`complete` 是全部窗口（查用量接口得到的），回复里带回的只有一部分 */
export type QuotaDetails = { kind: string; plan?: string; balance?: string; values: { name: string; display?: string; used?: number; unlimited?: boolean; balance?: number; unit?: string; resetsAt?: number }[] };
export type Quota = { provider: string; account: Account; status: "observed" | "unsupported" | "unobserved" | "failed"; windows: QuotaWindow[]; complete: boolean; observedAt?: number; activeScopes?: string[]; details?: QuotaDetails; accounts?: Quota[]; requestedAt?: number; owners?: Record<string, number> };

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

/** 能力与观测都经同一条 quota 消息；空查询不是新观测。
 * 身份：报告只归到这次结果实际用的、已解析出分区的授权；解析失败没有账号身份，记在这个提供方未解析的授权上（`scope=null`，不关联任何账号的数值）。
 * 账号与来源一级的报告（能力、失败、网关清单）的 `provider` 是模型在 Pi 里的提供方，网关清单里各账号的是上游。
 * 时间：带结果的报告都带 `requestedAt`，取结果所属操作期间的一个时刻（主动查询取开始，回复取收到），CuePad 据此只让后开始的覆盖先结束的。 */
export class QuotaFetcher {
	/** 正在查的额度：几个客户端同时要时共用这一次 */
	private inFlight: Promise<string[]> | null = null;

	private readonly ctx: ExtensionContext;
	private readonly report: (quota: Quota) => void;

	constructor(ctx: ExtensionContext, report: (quota: Quota) => void) {
		this.ctx = ctx;
		this.report = report;
	}

	fetchAll(): Promise<string[]> {
		this.inFlight ??= this.fetchSources().finally(() => { this.inFlight = null; });
		return this.inFlight;
	}

	private async fetchSources(): Promise<string[]> {
		const models = [...this.ctx.modelRegistry.getAvailable(), ...(this.ctx.model ? [this.ctx.model] : [])];
		if (models.length === 0) return ["no available quota sources"];
		// 先解析全部模型，再按来源各查一次：网关来源的报告带上解析到它的每个提供方与各自开始解析的时刻（`owners`），
		// 几个 Pi 提供方指向同一网关时，CuePad 才知道它们都证明过这个来源（不论在不在模型范围内、会话之后在不在线）。
		const resolutions = await Promise.allSettled(models.map(async (model) => {
			const requestedAt = Date.now() / 1000;
			try { return { model, requestedAt, resolved: await account(this.ctx, model) }; }
			catch (error) {
				this.report({ provider: model.provider, account: unresolvedAccount(this.ctx, model), status: "failed", windows: [], complete: false, requestedAt });
				throw error;
			}
		}));
		const groups = new Map<string, { model: Model; requestedAt: number; resolved: Awaited<ReturnType<typeof account>>; owners: Record<string, number> }>();
		for (const result of resolutions) {
			if (result.status === "rejected") continue;
			const { model, requestedAt, resolved } = result.value;
			const key = resolved.native ? `${model.provider}/${resolved.identity.scope}` : resolved.identity.source!;
			const group = groups.get(key) ?? { model, requestedAt, resolved, owners: {} };
			group.owners[model.provider] = Math.max(group.owners[model.provider] ?? 0, requestedAt);
			groups.set(key, group);
		}
		const fetches = await Promise.allSettled([...groups.values()].map(async ({ model, requestedAt, resolved, owners }) => {
			try {
				if (resolved.native) await this.fetchNative(model, resolved, requestedAt);
				else await gatewayQuotas(model.provider, resolved, this.report, requestedAt, owners);
			} catch (error) {
				this.report({ provider: model.provider, account: resolved.identity, status: "failed", windows: [], complete: false, requestedAt, ...(resolved.native ? {} : { owners }) });
				throw error;
			}
		}));
		return [...resolutions, ...fetches].flatMap((result) => result.status === "rejected" ? [reason(result.reason)] : []);
	}

	/** 能力声明不带排序时刻，所以不报失败（失败只来自带时刻的查询）：未解析的只报其他提供方的 OAuth（`modelInfo` 不解析它们，只是还没查），
	 * 其余未解析的是解析失败，不在这里声明。 */
	capabilities(models: { provider: string; account: Account | null }[], currentProvider: string | undefined) {
		const seen = new Set<string>();
		for (const model of models) {
			if (!model.account || (!model.account.scope && (model.provider === currentProvider || model.account.kind !== "oauth"))) continue;
			const key = model.account.source ?? `${model.provider}/${model.account.scope}`;
			if (seen.has(key)) continue;
			seen.add(key);
			const supported = model.account.source || (model.account.kind === "oauth" && QUOTA_PROVIDERS[model.provider]);
			this.report({ provider: model.provider, account: model.account, status: supported ? "unobserved" : "unsupported", windows: [], complete: false });
		}
	}

	private async fetchNative(model: Model, resolved: Awaited<ReturnType<typeof account>>, requestedAt: number) {
		const provider = model.provider, identity = resolved.identity;
		const source = QUOTA_PROVIDERS[provider];
		if (!source || identity.kind !== "oauth") {
			this.report({ provider, account: identity, status: "unsupported", windows: [], complete: true, requestedAt });
			return;
		}
		if (!resolved.token) throw new Error(`${provider}: no token`);
		const headers = new Headers(resolved.headers);
		for (const [key, value] of Object.entries(source.headers(resolved.token))) headers.set(key, value);
		headers.set("Accept", "application/json");
		const response = await fetch(source.url, { headers, signal: AbortSignal.timeout(QUOTA_TIMEOUT_MS), redirect: "error" });
		if (!response.ok) throw new Error(`${provider}: HTTP ${response.status}`);
		const windows = source.parse(await response.json());
		if (windows.length === 0) throw new Error(`${provider}: unrecognized usage format`);
		this.report({ provider, account: identity, status: "observed", windows, complete: true, requestedAt, observedAt: Date.now() / 1000 });
	}
}
