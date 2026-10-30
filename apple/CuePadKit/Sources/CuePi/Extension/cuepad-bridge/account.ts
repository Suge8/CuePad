import { createHash } from "node:crypto";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export type Account = { kind: "oauth" | "apiKey"; scope: string | null };

/** 宿主决定认证路线并解析授权；桥只传不可逆的授权分区，不读登录文件、不解析 ChatGPT 凭据、不刷新。
 * 分区包含完整请求授权，令牌轮换宁可开始新观测，也不能把另一账号、工作区或授权应用的窗口沿用过来。 */
export function accountKind(ctx: ExtensionContext, provider: string): Account["kind"] {
	const registry = ctx.modelRegistry;
	const model = registry.getAll().find((model) => model.provider === provider) ?? ctx.model;
	return model?.provider === provider && registry.isUsingOAuth(model) ? "oauth" : "apiKey";
}

export async function account(ctx: ExtensionContext, provider: string) {
	const registry = ctx.modelRegistry;
	const kind = accountKind(ctx, provider);
	if (kind === "apiKey") return { identity: { kind, scope: null } as Account, auth: null };
	const resolved = await registry.getProviderAuth(provider);
	if (!resolved) throw new Error(`${provider}: no authorization`);
	const scope = createHash("sha256").update(JSON.stringify([provider, resolved.auth])).digest("hex");
	return { identity: { kind, scope } as Account, auth: resolved.auth };
}
