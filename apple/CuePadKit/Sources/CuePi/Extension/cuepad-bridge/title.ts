// 按第一句话给会话起短名（CuePad 的 `title` 命令）：只回不写——CuePad 核对过任务标题与改名请求后，用 `config` 改名写回。
// 只在会话所在 provider 里挑最便宜的可用模型：数据不发给别家。

import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Ack, Session } from "./session.ts";

type Model = NonNullable<ExtensionContext["model"]>;

const price = (model: Model) => model.cost.input + model.cost.output;

export function namingModel(ctx: ExtensionContext): Model | undefined {
	const current = ctx.model;
	if (!current) return undefined;
	const mine = ctx.modelRegistry.getAvailable().filter((model) => model.provider === current.provider);
	const lowest = Math.min(price(current), ...mine.map(price));
	if (price(current) === lowest) return current;
	return mine.find((model) => price(model) === lowest);
}

export async function handleTitle(session: Session, command: Record<string, unknown>, ack: Ack, reject: (error: string) => void) {
	const { ctx } = session;
	const { instructions, text, limit, timeoutMs } = command;
	if (typeof instructions !== "string" || typeof text !== "string" || !text.trim() || typeof limit !== "number" || typeof timeoutMs !== "number") {
		return reject("bad_request");
	}
	const model = namingModel(ctx);
	if (!model) return reject("no_model");
	const signal = AbortSignal.any([AbortSignal.timeout(timeoutMs), session.lifetime.signal]);
	const reply = await ctx.modelRegistry.streamSimple(
		model,
		{ systemPrompt: instructions, messages: [{ role: "user", content: [{ type: "text", text }], timestamp: Date.now() }] },
		{ signal, maxTokens: 64, cacheRetention: "none" },
	).result();
	if (reply.stopReason !== "stop") return reject(`failed: ${reply.errorMessage ?? reply.stopReason}`);
	// 与 Swift 一侧的 `SessionNameSuggestion.cleaned` 各实现一份同一条规则
	const said = reply.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
	const title = [...(said.split("\n")[0] ?? "").trim()].slice(0, limit).join("").trim();
	if (!title) return reject("failed: empty title");
	ack({ ok: true, title });
}
