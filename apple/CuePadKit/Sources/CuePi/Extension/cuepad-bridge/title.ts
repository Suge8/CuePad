// 按第一句话给会话起短名（CuePad 的 `title` 命令，`SessionNameSuggestion`）：只起名、回给 CuePad，写回由 CuePad 经 `config` 的会话名做。
// 用会话所在 provider 里最便宜的可用模型（只在你已登录的这一家里挑，数据不发给别家）；目录里都没标价（自建、本地的）就用会话当前的模型。
// 不开思考，说明与时限随命令来。

import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Ack, Session } from "./session.ts";

type Model = NonNullable<ExtensionContext["model"]>;

/** 每百万 token 的输入加输出价；没标价（0）的不算便宜，不挑 */
const price = (model: Model) => model.cost.input + model.cost.output;

export function namingModel(ctx: ExtensionContext): Model | undefined {
	const current = ctx.model;
	if (!current) return undefined;
	const priced = ctx.modelRegistry.getAvailable().filter((model) => model.provider === current.provider && price(model) > 0);
	return priced.reduce<Model | undefined>((best, model) => (!best || price(model) < price(best) ? model : best), undefined) ?? current;
}

export async function handleTitle(session: Session, command: Record<string, unknown>, ack: Ack, reject: (error: string) => void) {
	const { instructions, text, timeoutMs } = command;
	if (typeof instructions !== "string" || typeof text !== "string" || !text.trim() || typeof timeoutMs !== "number") return reject("bad_request");
	const model = namingModel(session.ctx);
	if (!model) return reject("no_model");
	const signal = AbortSignal.any([AbortSignal.timeout(timeoutMs), session.lifetime.signal]);
	const reply = await session.ctx.modelRegistry.streamSimple(
		model,
		{ systemPrompt: instructions, messages: [{ role: "user", content: [{ type: "text", text }], timestamp: Date.now() }] },
		{ signal, maxTokens: 64, cacheRetention: "none" },
	).result();
	if (reply.stopReason !== "stop") return reject(`failed: ${reply.errorMessage ?? reply.stopReason}`);
	const title = reply.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("").trim();
	if (!title) return reject("failed: empty title");
	ack({ ok: true, title });
}
