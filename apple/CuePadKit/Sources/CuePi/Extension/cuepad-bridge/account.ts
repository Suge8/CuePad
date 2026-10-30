import { createHash } from "node:crypto";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export type Account = { kind: "oauth" | "apiKey"; scope: string | null; source?: string; route?: string; name?: string };
export type Model = NonNullable<ExtensionContext["model"]>;

export function partition(value: unknown): string {
	return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

const NATIVE_URLS: Record<string, string> = {
	anthropic: "https://api.anthropic.com", "openai-codex": "https://chatgpt.com/backend-api", openai: "https://api.openai.com/v1",
};

/** 一次证明了的授权与开始解析的时刻（Unix 秒）。 */
export type Proof = { account: Account; at: number };
/** 每个模型最近一次证明的授权（按解析开始的先后，晚开始的才覆盖）；解析失败不抹掉它。只用来让 CuePad 决定保留哪些记录（`provenAccount`），
 * 不拿来关联额度或归属任何报告：那只认这一次解析的结果。 */
const proofs = new WeakMap<ExtensionContext["modelRegistry"], Map<string, Proof & { order: number }>>();
let resolutions = 0;
const modelKey = (model: Model) => JSON.stringify([model.provider, model.id]);

export function provenAccount(ctx: ExtensionContext, model: Model): Proof | undefined {
	const proof = proofs.get(ctx.modelRegistry)?.get(modelKey(model));
	return proof && { account: proof.account, at: proof.at };
}

/** 请求路线与认证只问宿主；自定义地址不冒充原生 OAuth。只把不可逆分区交给 App。
 * `confirm`：主动查询时的解析，证明时刻总是推进到这一次（CuePad 据此清理换掉的授权）；
 * 其余（每轮前取模型表）同一授权沿用原时刻，模型表不随每次解析变化。 */
export async function account(ctx: ExtensionContext, model: Model, confirm = false) {
	const order = ++resolutions, at = Date.now() / 1000;
	const resolved = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!resolved.ok) throw new Error(`${model.provider}: authorization unavailable`);
	const baseUrl = (resolved.baseUrl ?? model.baseUrl).replace(/\/+$/, "");
	const headers = new Headers();
	const kind = ctx.modelRegistry.isUsingOAuth(model) ? "oauth" : "apiKey";
	if (resolved.apiKey) {
		if (model.api === "anthropic-messages" && kind === "apiKey") headers.set("x-api-key", resolved.apiKey);
		else headers.set("Authorization", `Bearer ${resolved.apiKey}`);
	}
	for (const [key, value] of Object.entries({ ...model.headers, ...resolved.headers })) {
		if (value === null) headers.delete(key); else headers.set(key, value);
	}
	const scope = partition([baseUrl, [...headers].sort()]);
	const native = baseUrl === NATIVE_URLS[model.provider];
	const identity: Account = native ? { kind, scope } : { kind, scope, source: scope, name: "Magpie" };
	let proven = proofs.get(ctx.modelRegistry);
	if (!proven) proofs.set(ctx.modelRegistry, proven = new Map());
	const last = proven.get(modelKey(model));
	const same = !confirm && last && JSON.stringify(last.account) === JSON.stringify(identity);
	if ((last?.order ?? 0) < order) proven.set(modelKey(model), { order, at: same ? last!.at : at, account: identity });
	return { identity, baseUrl, headers, native, token: resolved.apiKey };
}

export function unresolvedAccount(ctx: ExtensionContext, model: Model): Account {
	return { kind: ctx.modelRegistry.isUsingOAuth(model) ? "oauth" : "apiKey", scope: null };
}
