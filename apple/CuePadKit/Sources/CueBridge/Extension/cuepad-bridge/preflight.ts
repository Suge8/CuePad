import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { reason } from "./info.ts";

type Failure = { code: string; detail: string };

/** 只在交出前确认当前模型及授权；这不是宿主受理或持久化回执，之后没有关联事件仍是未知。 */
export async function preflight(ctx: ExtensionContext): Promise<Failure | undefined> {
	const model = ctx.model;
	if (!model) return { code: "unknown_model", detail: "No model selected" };
	try {
		if (!ctx.modelRegistry.hasConfiguredAuth(model) && !(await ctx.modelRegistry.getProviderAuth(model.provider))) {
			return { code: "no_auth", detail: `No API key or provider authorization found for "${model.provider}"` };
		}
		const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
		if (!auth.ok) return { code: `failed: ${auth.error}`, detail: auth.error };
		if (ctx.model?.provider !== model.provider || ctx.model?.id !== model.id) {
			return { code: "failed: model changed before dispatch", detail: "Model changed before dispatch" };
		}
	} catch (error) {
		const detail = reason(error);
		return { code: `failed: ${detail}`, detail };
	}
}
