import { partition, type account } from "./account.ts";
import { record, type Quota, type QuotaWindow } from "./quota.ts";

const TIMEOUT_MS = 10_000;
const UNITS: Record<string, number> = { hour: 3600, hours: 3600, day: 86_400, days: 86_400, week: 604_800, weeks: 604_800 };

/** 公共接口只给显示名；只认明确的固定周期，不用离重置还有多久反推窗口。 */
function windowsOf(value: unknown): QuotaWindow[] {
	if (!Array.isArray(value)) return [];
	return value.flatMap((value) => {
		const window = record(value);
		if (window.text || window.unlimited || window.balance !== undefined) return [];
		const span = typeof window.name === "string" ? /^(\d+) (hours?|days?|weeks?)$/.exec(window.name) : null;
		const resetsAt = date(window.resetsAt);
		if (!span || resetsAt === null || typeof window.used !== "number" || !Number.isFinite(window.used) || window.used < 0) return [];
		const seconds = Number(span[1]) * UNITS[span[2]];
		return seconds > 0 ? [{ seconds, used: window.used / 100, resetsAt, model: null }] : [];
	});
}

function date(value: unknown): number | null {
	if (typeof value !== "string") return null;
	const stamp = Date.parse(value) / 1000;
	return Number.isFinite(stamp) ? stamp : null;
}

/** 同一个实际地址与认证只查一次。不转发凭据到重定向，不读上游登录文件。 */
export async function gatewayQuotas(provider: string, resolved: Awaited<ReturnType<typeof account>>, report: (quota: Quota) => void) {
	const headers = new Headers(resolved.headers);
	headers.set("Accept", "application/json");
	const response = await fetch(`${resolved.baseUrl}/magpie/quotas`, { headers, signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "error" });
	if ([404, 405, 501].includes(response.status)) {
		report({ provider, account: resolved.identity, status: "unsupported", windows: [], complete: true });
		return;
	}
	if (!response.ok) throw new Error(`${provider}: quota HTTP ${response.status}`);
	const body = record(await response.json());
	if (!Array.isArray(body.data)) throw new Error(`${provider}: unrecognized quota response`);
	const source = resolved.identity.source!;
	if (body.data.length === 0) {
		report({ provider, account: resolved.identity, status: "unobserved", windows: [], complete: true, activeScopes: [] });
		return;
	}
	const activeScopes: string[] = [];
	for (const value of body.data) {
		const card = record(value);
		if (typeof card.provider !== "string" || !card.provider || typeof card.kind !== "string") throw new Error(`${provider}: invalid quota account`);
		const user = typeof card.user === "string" ? card.user : "";
		const name = ["Magpie", card.name ?? card.provider, card.alias || card.seat || user].filter(Boolean).join(" / ");
		const identity = { kind: resolved.identity.kind, source, scope: partition([source, card.provider, card.kind, user || card.alias || card.seat || card.name || "", card.from ?? ""]), route: card.provider, name };
		if (activeScopes.includes(identity.scope)) throw new Error(`${provider}: ambiguous quota accounts`);
		activeScopes.push(identity.scope);
		const windows = windowsOf(card.windows);
		const observedAt = date(card.readAt);
		const status = card.error ? "failed" : card.readDeferred && windows.length === 0 ? "unobserved"
			: card.kind === "balance" || windows.length === 0 ? "unsupported" : observedAt === null ? "unobserved" : "observed";
		report({ provider: card.provider, account: identity, status, windows: observedAt === null ? [] : windows, complete: true,
			...(observedAt === null ? {} : { observedAt }) });
	}
	report({ provider, account: resolved.identity, status: "unobserved", windows: [], complete: true, activeScopes });
}
