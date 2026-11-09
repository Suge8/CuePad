// 把出错的那一轮原样重跑一遍（`retry` 命令）。Pi 没有给扩展"接着上次的上下文再请求一次"的接口（`agent.continue()` 只在 Pi 自己的重试里用），
// 能起一轮的只有消息：这里投一条不显示的自定义消息（`RETRY_TYPE`）开轮，再让它与出错的助手消息都不进请求、也不留在上下文里——
// 对话里不多一句话、模型也不会读到"继续"；已完成的用户与工具消息保留，不回退分支重放。
// 去掉分两处（`context` 请求、`turn_end` 边界），都只认消息本身、不记状态：重载扩展、半路退出后下次的请求与边界照样清得掉。

import type { ContextEvent, SessionBoundaryDraft, TurnEndEvent } from "@earendil-works/pi-coding-agent";
import type { Ack, Session } from "./session.ts";

const RETRY_TYPE = "cuepad-retry";
/** 只在 Pi 自己的界面或会话文件里看得到；请求里没有它 */
const RETRY_TEXT = "Retry the failed request.";
export const NOTHING_TO_RETRY = "nothing_to_retry";

type Message = ContextEvent["messages"][number];

const isRetryMessage = (message: Message) => message.role === "custom" && message.customType === RETRY_TYPE;
const isFailedAnswer = (message: Message | undefined) => message?.role === "assistant" && (message.stopReason === "error" || message.stopReason === "length");

/** 返回拒绝原因，受理返回 undefined。确认只表示观察到隐藏消息事件，不是落盘或模型成功。
 * 没有可关联事件时超时仍是未知。 */
export async function retry(session: Session, ack: Ack): Promise<string | undefined> {
	const { ctx, pi } = session;
	const failed = isFailedAnswer(ctx.sessionManager.buildSessionProjection().messages.at(-1));
	if (session.phase !== "error" || !failed || !ctx.isIdle()) return NOTHING_TO_RETRY;
	if (!(await session.prepare(ack))) return;
	// 预检期间另一个重跑已经交出：它的确认还在等，不能被覆盖
	if (session.phase !== "error" || !ctx.isIdle() || session.retrying) return NOTHING_TO_RETRY;
	settleRetry(session);
	session.retrying = ack;
	try {
		pi.sendMessage({ customType: RETRY_TYPE, content: RETRY_TEXT, display: false }, { triggerTurn: true });
	} catch (error) {
		session.retrying = null;
		throw error;
	}
}

/** 真实歇下仍没观察到 marker：释放协议等待，不据此承诺没有执行。 */
export function settleRetry(session: Session) {
	const ack = session.retrying;
	session.retrying = null;
	const outcome = session.tracker.outcome;
	ack?.({ ok: false, error: `failed: ${outcome.kind === "error" ? outcome.error : "retry settled before its start was observed"}` });
}

export function landed(session: Session, message: Message) {
	if (!isRetryMessage(message) || !session.retrying) return;
	const ack = session.retrying;
	session.retrying = null;
	ack({ ok: true });
}

/** 只影响这一次请求。 */
export function stripFromRequest(event: ContextEvent): { messages: Message[] } | undefined {
	const omitted = new Set<number>();
	event.messages.forEach((message, index) => {
		if (!isRetryMessage(message)) return;
		omitted.add(index);
		if (isFailedAnswer(event.messages[index - 1])) omitted.add(index - 1);
	});
	if (omitted.size === 0) return;
	return { messages: event.messages.filter((_message, index) => !omitted.has(index)) };
}

/** 追加 `context_edit`（replacement 为 null）把它与前面那条出错的助手消息从投影里去掉，做法同 Pi 自己的重试（`_omitRecoveryAttempt`）；
 * 原始记录仍在会话文件里，CuePad 读对话时不显示它（display 为 false）。 */
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
