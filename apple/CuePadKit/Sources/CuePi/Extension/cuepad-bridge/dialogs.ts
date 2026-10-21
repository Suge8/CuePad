import { randomUUID } from "node:crypto";
import type { ExtensionUIContext, ExtensionUIDialogOptions } from "@earendil-works/pi-coding-agent";
import type { Question } from "./info.ts";

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
