import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

type Model = ExtensionContext["model"];

export function supportsFast(model: Model): boolean {
	return model?.api === "openai-responses" || model?.api === "openai-codex-responses";
}

/** 请求前写上 `service_tier=priority`（`before_provider_request` 的返回值）；模型不支持或请求体不是对象时不改。 */
export function prioritized(payload: unknown, model: Model): object | undefined {
	if (!supportsFast(model) || !payload || typeof payload !== "object" || Array.isArray(payload)) return;
	return { ...payload, service_tier: "priority" };
}
