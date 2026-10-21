// Pi 事件 → 会话的状态、近况、正在说的话与额度。

import { modelInfo } from "./info.ts";
import { claudeHeaderWindows, codexWindows, record } from "./quota.ts";
import type { Session } from "./session.ts";
import { toolDetail } from "./state.ts";
import { clip, messageText, preview } from "./text.ts";

/** 等你回答的弹窗文案的字符数上限（含省略号） */
const QUESTION_LIMIT = 500;

/** 订阅这个会话要跟的 Pi 事件，返回退订的函数。 */
export function follow(session: Session): (() => void)[] {
	const { pi, ctx, tracker, draft, pending } = session;
	const refreshContext = () => session.refreshContext();
	const finishCompaction = () => session.finishCompaction();
	return [
		pi.on("model_select", () => { session.updateInfo(modelInfo(pi, ctx)); refreshContext(); }),
		pi.on("thinking_level_select", () => session.updateInfo({ thinking: ctx.model ? pi.getThinkingLevel() : null })),
		pi.on("before_agent_start", () => session.refreshCommands()),
		pi.on("turn_end", refreshContext),
		pi.on("agent_settled", refreshContext),
		pi.on("session_compact", refreshContext),
		pi.on("session_tree", refreshContext),
		pi.on("session_info_changed", (event) => session.updateInfo({ name: event.name ?? null })),
		pi.on("message_start", (event) => {
			if (event.message.role !== "assistant") return;
			// 同一次运行里的下一条（排队的话接着开的一轮）：上一条已经说完落库，不再是此刻在说的
			draft.restart();
		}),
		pi.on("message_end", (event) => {
			if (event.message.role === "assistant") {
				const stop = event.message.stopReason;
				return stop === "toolUse" || stop === "aborted" || stop === "error" ? draft.clear() : draft.grow(event.message, true);
			}
			if (event.message.role !== "user") return;
			// 首条消息与 Pi 会话列表一致，不区分机器消息
			session.updateInfo({ firstMessage: session.firstMessage ?? preview(messageText(event.message)) });
			// 交出的那句落成了消息（带图时 Pi 在文字后附上图片说明，所以按开头认）：投送请求 id 写到它上面，再确认送达。
			// 扩展先收到 message_end、Pi 再把同一个消息对象写进会话文件，所以 id 随消息落盘，对话（读会话文件）据此认出它
			const said = session.starting;
			if (!said || !messageText(event.message).startsWith(said.text)) return;
			session.starting = null;
			if (said.id) Object.assign(event.message, { cuepadDelivery: said.id });
			said.ack?.({ ok: true });
		}),

		// ---- Pi 事件 → 状态 ----
		// 提交了一条消息（你的提问，或扩展投进来的，如 FireCode 交回子代理结果）：这一轮从这里开始算。
		// FireCode 交回结果时，在飞数在这之后、agent_start 之前就归零了，从这里接上，连续处理才不会在交接处断开。
		// 自己交出的话从 agent_start 起算：Pi 在 input 之后才查模型与登录，拒收了这里就会一直报工作中
		pi.on("input", (event) => {
			if (tracker.active || session.starting?.text === event.text) return;
			tracker.active = true;
			session.commit();
		}),
		pi.on("agent_start", () => {
			tracker.active = true;
			tracker.settled = null;
			tracker.outcome = { kind: "done" };
			tracker.stopped = false;
			session.commit();
			draft.clear();
			// 还有话等着：这一轮（多半是上一句开的）先停下，让下一句开新一轮
			if (pending.length > 0) session.stopRound();
		}),
		pi.on("turn_start", (event) => {
			session.turnSince = event.timestamp;
			session.commit();
		}),
		pi.on("message_update", (event) => {
			const type = event.assistantMessageEvent.type;
			if (type === "text_delta") draft.grow(event.message);
			if (type === "toolcall_start") draft.close();
		}),
		pi.on("tool_execution_start", (event) => { tracker.tools.set(event.toolCallId, { name: event.toolName, detail: toolDetail(event.args) }); session.commit(); }),
		pi.on("tool_execution_end", (event) => { tracker.tools.delete(event.toolCallId); session.commit(); }),
		pi.on("ui_prompt_start", (event) => {
			tracker.prompt = { title: event.title };
			const question = session.asking ?? { id: null, kind: event.kind, text: event.title ?? "", options: [] };
			session.updateInfo({ question: { id: question.id, kind: question.kind, text: clip(question.text, QUESTION_LIMIT) ?? "", options: question.options } });
			session.commit();
		}),
		pi.on("ui_prompt_end", () => {
			tracker.prompt = null;
			session.asking = null;
			session.updateInfo({ question: null });
			session.commit();
		}),
		pi.on("session_before_compact", () => {
			session.beforeCompaction = { phase: session.phase, since: session.since, busySince: session.busySince };
			tracker.compacting = true;
			session.commit();
		}),
		pi.on("session_compact", finishCompaction),
		pi.on("session_compact_failed", finishCompaction),
		// 被停下的一轮有时以 error 结束（Pi 1.2 在工具被中止后再请求模型、请求因中止失败时记成 error）：只认确定的事实——
		// 这一轮收到过停止、或这一轮的中止信号已触发——按被停下报，不看错误文案
		pi.on("agent_end", (event, context) => {
			const last = event.messages.findLast((m) => m.role === "assistant");
			const stopped = tracker.stopped || context.signal?.aborted === true;
			if (last?.stopReason === "aborted" || (last?.stopReason === "error" && stopped)) tracker.outcome = { kind: "done" };
			else if (last?.stopReason === "error") tracker.outcome = { kind: "error", error: last.errorMessage ?? "unknown" };
		}),
		// 订阅额度随每次回复带回来（零额外请求）：Claude 在响应头里，Codex 在流里的 codex.rate_limits 事件里
		pi.on("after_provider_response", (event, context) => {
			const provider = context.model?.provider;
			if (provider === "anthropic") session.reportQuota({ provider, windows: claudeHeaderWindows(event.headers), complete: false });
		}),
		pi.on("provider_stream_event", (event) => {
			const data = record(event.data);
			if (event.provider !== "openai-codex" || data.type !== "codex.rate_limits") return;
			session.reportQuota({ provider: event.provider, windows: codexWindows(record(data.rate_limits), "primary", "secondary", "window_minutes", 60), complete: true });
		}),
		pi.on("agent_settled", () => {
			// 还有话等着：被它停下的这一轮不算歇下，接着就是它开的那一轮（`submitPending`）
			tracker.active = pending.length > 0;
			tracker.tools.clear();
			tracker.settled = tracker.active ? null : tracker.outcome;
			session.commit();
			session.submitPending();
		}),
	];
}
