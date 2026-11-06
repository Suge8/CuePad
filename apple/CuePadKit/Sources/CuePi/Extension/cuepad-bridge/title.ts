// 按第一句话给会话起短名（CuePad 的 `title` 命令，`SessionNameSuggestion`）：会话还没名字就用 Pi 的改名接口写下（CuePad 照会话名读回），
// 起名途中有了名字（你改了名）就不动。
// 用会话所在 provider 里最便宜的可用模型（只在你已登录的这一家里挑，数据不发给别家）：按目录标价取最低，同价的有当前模型就用它——
// 都没标价（自建、本地的）时就是当前模型。不开思考；说明、长度上限与时限随命令来。

import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Ack, Session } from "./session.ts";

type Model = NonNullable<ExtensionContext["model"]>;

/** 每百万 token 的输入加输出价 */
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
	const { pi, ctx } = session;
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
	// 同 `SessionNameSuggestion.cleaned`：第一行、去掉首尾空白、截到上限
	const said = reply.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
	const title = [...(said.split("\n")[0] ?? "").trim()].slice(0, limit).join("").trim();
	if (!title) return reject("failed: empty title");
	if (!pi.getSessionName()) pi.setSessionName(title);
	ack({ ok: true });
}
