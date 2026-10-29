// Pi 这一端：事件 → 会话的状态、近况、正在说的话与额度；状态的推导；弹窗的捕获。

import { randomUUID } from "node:crypto";
import path from "node:path";
import type { ExtensionUIContext, ExtensionUIDialogOptions } from "@earendil-works/pi-coding-agent";
import { clip, messageText, modelInfo, preview, type Question } from "./info.ts";
import { omitFromContext, landed, stripFromRequest } from "./retry.ts";
import { claudeHeaderWindows, codexWindows, record } from "./quota.ts";
import type { Session } from "./session.ts";


/** 等你回答的弹窗文案的字符数上限（含省略号） */
const QUESTION_LIMIT = 500;

/** 订阅这个会话要跟的 Pi 事件，返回退订的函数。 */
export function follow(session: Session): (() => void)[] {
	const { pi, ctx, tracker, draft, pending } = session;
	const refreshContext = () => session.refreshContext();
	const finishCompaction = () => session.finishCompaction();
	return [
		pi.on("model_select", async () => { session.updateInfo(await modelInfo(pi, ctx)); refreshContext(); }),
		pi.on("thinking_level_select", () => session.updateInfo({ thinking: ctx.model ? pi.getThinkingLevel() : null })),
		pi.on("before_agent_start", () => session.refreshCommands()),
		pi.on("turn_end", refreshContext),
		pi.on("context", stripFromRequest),
		pi.on("turn_end", omitFromContext),
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
			if (event.message.role === "custom") return landed(session, event.message);
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
			else if (last?.stopReason === "length") tracker.outcome = { kind: "error", error: "max_output_tokens" };
		}),
		// 订阅额度随每次回复带回来（零额外请求）：Claude 在响应头里，Codex 在流里的 codex.rate_limits 事件里
		pi.on("after_provider_response", (event, context) => {
			const provider = context.model?.provider;
			if (provider === "anthropic") session.observeQuota(provider, claudeHeaderWindows(event.headers), false);
		}),
		pi.on("provider_stream_event", (event) => {
			const data = record(event.data);
			if (event.provider !== "openai-codex" || data.type !== "codex.rate_limits") return;
			session.observeQuota(event.provider, codexWindows(record(data.rate_limits), "primary", "secondary", "window_minutes", 60), true);
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

/** 工具状态里一句话详情的字符数上限（含省略号） */
const DETAIL_LIMIT = 120;

type State =
	| { kind: "idle" }
	/** 工作中、没在调工具：正在出字也算（正在说的话另走 `draft`） */
	| { kind: "thinking" }
	| { kind: "tool"; tool: string; detail?: string }
	/** 自己这轮已经歇下，还有子代理在飞：仍在处理 */
	| { kind: "delegating" }
	/** 在压缩上下文：手动 /compact、上下文快满时自动压缩、上下文溢出后压缩再重试，都是它 */
	| { kind: "compacting" }
	| { kind: "waiting_user"; title?: string }
	| { kind: "done" }
	| { kind: "error"; error: string };

/** 事件只更新变量，对外状态只由 derive() 推导。 */
export class StateTracker {
	active = false;
	tools = new Map<string, { name: string; detail?: string }>();
	prompt: { title?: string } | null = null;
	/** agent_end 记录结果，agent_settled 才生效：重试/压缩/排队消息都可能在 agent_end 之后继续 */
	outcome: State = { kind: "done" };
	/** 这一轮收到过 CuePad 的停止（`abort` 命令） */
	stopped = false;
	settled: State | null = null;
	/** session_before_compact 到 session_compact / session_compact_failed */
	compacting = false;

	/** `inFlight`：在飞子代理数（FireCode 发布） */
	derive(inFlight: number): State {
		if (this.prompt) return { kind: "waiting_user", title: this.prompt.title };
		if (this.compacting) return { kind: "compacting" };
		if (this.active) {
			if (this.tools.size > 0) {
				const latest = [...this.tools.values()].at(-1)!;
				return { kind: "tool", tool: latest.name, detail: latest.detail };
			}
			return { kind: "thinking" };
		}
		if (inFlight > 0) return { kind: "delegating" };
		return this.settled ?? { kind: "idle" };
	}
}

export type Phase = "working" | "waiting" | "error" | "idle";

/** 某一刻的粗状态与计时（压缩前记下，压完回到同一个粗状态时恢复） */
export type Clock = { phase: Phase; since: number; busySince: number | null };

/** 粗状态：计时只在它变化时动，思考、工具、等子代理之间切换不算。 */
export function phaseOf(state: State): Phase {
	switch (state.kind) {
		case "thinking": case "tool": case "delegating": case "compacting": return "working";
		case "waiting_user": return "waiting";
		case "error": return "error";
		default: return "idle";
	}
}

/** 只上报一句话摘要，不上报完整参数：命令/搜索模式取首个非空行，文件类工具取文件名，超长截断。 */
function toolDetail(args: Record<string, unknown> | undefined): string | undefined {
	const raw = typeof args?.command === "string" ? args.command
		: typeof args?.pattern === "string" ? args.pattern
		: typeof args?.path === "string" ? path.basename(args.path) : undefined;
	const line = raw?.split("\n").map((l) => l.trim()).find((l) => l.length > 0);
	if (!line) return undefined;
	const chars = Array.from(line);
	return chars.length <= DETAIL_LIMIT ? line : chars.slice(0, DETAIL_LIMIT - 1).join("") + "…";
}

/** 标记已经包装过的 ui 对象 */
const CAPTURED = Symbol("cuepad.captured");
type DialogMethod = (...args: unknown[]) => unknown;

/** 正在弹出的对话框（最外层）。ui_prompt_start 只带标题，说明与选项要在调用时记下；`settle` 从 CuePad 作答 */
export type Asking = Question & { settle?: (value: unknown) => void; dismiss?: () => void };

/** 包装所有扩展共用的 ui 对象上的对话框方法（Pi 每次绑定界面都换新对象，session_start 前绑定）：记下文案与选项，
 * 并给弹窗接上一个由我们控制的 AbortSignal。从 CuePad 作答时先记下答案再 abort：Pi 的界面随之收起
 * （TUI 隐藏选择器，RPC 删掉待答请求），原调用按"取消"结束，包装把它换成我们的答案交回调用方。
 * `session.asking` 是此刻弹出的那个。 */
export function captureDialogs(context: ExtensionUIContext, session: { asking: Asking | null }) {
	const ui = context as unknown as Record<string, DialogMethod | undefined> & { [CAPTURED]?: true };
	if (ui[CAPTURED]) return;
	ui[CAPTURED] = true;
	/** `optionsAt`：对话框选项参数（含 signal）的位置；没有的（editor）不能从外面收起，只记文案 */
	const wrap = (method: string, kind: string, optionsAt: number | null, describe: (args: unknown[]) => { lines: unknown[]; options?: unknown }) => {
		const original = ui[method];
		if (typeof original !== "function") return;
		ui[method] = (...args) => {
			// 嵌套弹窗只算最外层，与 ui_prompt_start 一致
			if (session.asking) return original.apply(ui, args);
			const { lines, options } = describe(args);
			const question: Question = {
				id: optionsAt === null ? null : randomUUID(),
				kind,
				text: lines.filter((line): line is string => typeof line === "string" && line.length > 0).join("\n"),
				options: Array.isArray(options) ? options.filter((option): option is string => typeof option === "string") : [],
			};
			if (optionsAt === null) {
				session.asking = question;
				return original.apply(ui, args);
			}
			// 调用方自己的 signal 与我们的合在一起：任一触发都收起弹窗
			const own = new AbortController();
			const callerOptions = args[optionsAt] as ExtensionUIDialogOptions | undefined;
			const caller = callerOptions?.signal;
			let answer: { value: unknown } | undefined;
			session.asking = { ...question, settle: (value) => { answer = { value }; own.abort(); }, dismiss: () => own.abort() };
			const call = [...args];
			call[optionsAt] = { ...callerOptions, signal: caller ? AbortSignal.any([caller, own.signal]) : own.signal };
			return Promise.resolve(original.apply(ui, call)).then((value: unknown) => (answer ? answer.value : value));
		};
	};
	wrap("select", "select", 2, ([title, options]) => ({ lines: [title], options }));
	wrap("confirm", "confirm", 2, ([title, message]) => ({ lines: [title, message] }));
	wrap("input", "text", 2, ([title]) => ({ lines: [title] }));
	wrap("editor", "editor", null, ([title]) => ({ lines: [title] }));
}
