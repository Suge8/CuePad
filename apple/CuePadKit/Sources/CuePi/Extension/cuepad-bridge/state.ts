import path from "node:path";

/** 工具状态里一句话详情的字符数上限（含省略号） */
const DETAIL_LIMIT = 120;

export type State =
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
export function toolDetail(args: Record<string, unknown> | undefined): string | undefined {
	const raw = typeof args?.command === "string" ? args.command
		: typeof args?.pattern === "string" ? args.pattern
		: typeof args?.path === "string" ? path.basename(args.path) : undefined;
	const line = raw?.split("\n").map((l) => l.trim()).find((l) => l.length > 0);
	if (!line) return undefined;
	const chars = Array.from(line);
	return chars.length <= DETAIL_LIMIT ? line : chars.slice(0, DETAIL_LIMIT - 1).join("") + "…";
}
