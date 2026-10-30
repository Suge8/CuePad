import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

type Model = ExtensionContext["model"];

export function supportsFast(model: Model): boolean {
	return model?.api === "openai-responses" || model?.api === "openai-codex-responses";
}
