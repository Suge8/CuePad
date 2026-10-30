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

/** 每个模型最近一次证明的授权（按解析开始的先后，晚开始的才覆盖）；解析失败不抹掉它。只用来让 CuePad 保留它的记录（`provenAccount`），
 * 不拿来关联额度或归属任何报告：那只认这一次解析的结果。 */
const proofs = new WeakMap<ExtensionContext["modelRegistry"], Map<string, { started: number; identity: Account }>>();
let resolutions = 0;
const modelKey = (model: Model) => JSON.stringify([model.provider, model.id]);

export function provenAccount(ctx: ExtensionContext, model: Model): Account | undefined {
	return proofs.get(ctx.modelRegistry)?.get(modelKey(model))?.identity;
}

/** 请求路线与认证只问宿主；自定义地址不冒充原生 OAuth。只把不可逆分区交给 App。 */
export async function account(ctx: ExtensionContext, model: Model) {
	const started = ++resolutions;
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
	if ((proven.get(modelKey(model))?.started ?? 0) < started) proven.set(modelKey(model), { started, identity });
	return { identity, baseUrl, headers, native, token: resolved.apiKey };
}

export function unresolvedAccount(ctx: ExtensionContext, model: Model): Account {
	return { kind: ctx.modelRegistry.isUsingOAuth(model) ? "oauth" : "apiKey", scope: null };
}
