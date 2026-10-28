// 把出错的那一轮原样重跑一遍（`retry` 命令）。Pi 没有给扩展"接着上次的上下文再请求一次"的接口（`agent.continue()` 只在 Pi 自己的重试里用），
// 能起一轮的只有消息：这里投一条不显示的自定义消息（`RETRY_TYPE`）开轮，再让它与出错的助手消息都不进请求、也不留在上下文里——
// 对话里不多一句话、模型也不会读到"继续"，请求与第一次一模一样。
//   · 请求（`context` 事件）：去掉这条消息与紧挨着它的出错助手消息，只影响这一次请求；
//   · 上下文（`turn_end` 边界）：追加 `context_edit`（replacement 为 null）把两者从投影里去掉，做法同 Pi 自己的重试（`_omitRecoveryAttempt`），
//     原始记录仍在会话文件里，CuePad 读对话时不显示它（display 为 false）。
// 两处都只认消息本身、不记状态：重载扩展、半路退出后下次的请求与边界照样清得掉。

import type { ContextEvent, SessionBoundaryDraft, TurnEndEvent } from "@earendil-works/pi-coding-agent";
import type { Ack, Session } from "./session.ts";

const RETRY_TYPE = "cuepad-retry";
/** 只在 Pi 自己的界面或会话文件里看得到；请求里没有它 */
const RETRY_TEXT = "Retry the failed request.";
/** 没有可重跑的一轮（会话在跑，或最后一轮不是出错结束的）的拒绝原因 */
export const NOTHING_TO_RETRY = "nothing_to_retry";

type Message = ContextEvent["messages"][number];

const isRetryMessage = (message: Message) => message.role === "custom" && message.customType === RETRY_TYPE;
const isFailedAnswer = (message: Message | undefined) => message?.role === "assistant" && message.stopReason === "error";

/** 重跑：最后一轮是 CuePad 报成出错的那一轮、会话歇着、没有正在交出的重跑，才开新一轮；返回拒绝原因，受理返回 undefined。
 * 确认等隐藏消息落成会话里的一条消息（`landed`）：Pi 拒收（没登录、没有模型）时不发任何事件，CuePad 到点按没送到报，同 `send`。 */
export function retry(session: Session, ack: Ack): string | undefined {
	const { ctx, pi } = session;
	const failed = isFailedAnswer(ctx.sessionManager.buildSessionProjection().messages.at(-1));
	if (session.phase !== "error" || !failed || !ctx.isIdle() || session.retrying) return NOTHING_TO_RETRY;
	session.retrying = ack;
	pi.sendMessage({ customType: RETRY_TYPE, content: RETRY_TEXT, display: false }, { triggerTurn: true });
}

/** 隐藏消息落成了：确认送达。 */
export function landed(session: Session, message: Message) {
	if (!isRetryMessage(message) || !session.retrying) return;
	session.retrying({ ok: true });
	session.retrying = null;
}

/** 这一次请求不带隐藏消息与它前面那条出错的助手消息；没有就返回 undefined（不改请求）。 */
export function stripFromRequest(event: ContextEvent): { messages: Message[] } | undefined {
	const at = event.messages.findLastIndex(isRetryMessage);
	if (at < 0) return;
	return { messages: event.messages.filter((message, index) => index !== at && !(index === at - 1 && isFailedAnswer(message))) };
}

/** 一轮结束时：上下文里还有隐藏消息，就把它与前面那条出错的助手消息一起从投影里去掉。 */
export function omitFromContext(event: TurnEndEvent): { entries: SessionBoundaryDraft[] } | undefined {
	const entries = event.context.contextEntries;
	const edits: SessionBoundaryDraft[] = [];
	entries.forEach((entry, index) => {
		if (entry.sourceEntry.type !== "custom_message" || entry.sourceEntry.customType !== RETRY_TYPE) return;
		edits.push({ type: "context_edit", targetId: entry.sourceEntry.id, replacement: null });
		// 前一条带消息的投影项（被去掉的项与只记状态的项没有消息，跳过）
		const before = entries.slice(0, index).findLast((earlier) => earlier.messages.length > 0);
		if (before && isFailedAnswer(before.messages.at(-1))) edits.push({ type: "context_edit", targetId: before.sourceEntry.id, replacement: null });
	});
	return edits.length > 0 ? { entries: edits } : undefined;
}
