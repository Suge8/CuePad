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

/** 请求路线与认证只问宿主；自定义地址不冒充原生 OAuth。只把不可逆分区交给 App。 */
export async function account(ctx: ExtensionContext, model: Model) {
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
	const identity: Account = native ? { kind, scope } : { kind, scope, source: scope };
	return { identity, baseUrl, headers, native, token: resolved.apiKey };
}

export function unresolvedAccount(ctx: ExtensionContext, model: Model): Account {
	return { kind: ctx.modelRegistry.isUsingOAuth(model) ? "oauth" : "apiKey", scope: null };
}
