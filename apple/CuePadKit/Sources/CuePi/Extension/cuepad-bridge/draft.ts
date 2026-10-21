import { replyText } from "./text.ts";

/** 正在说的话（`draft`）最多每这么久上报一次：增量在这里合并，这条说完时立即补发最后一次 */
const DRAFT_INTERVAL_MS = 100;

/**
 * 正在说的话（`draft`）：主会话当前这条助手消息到目前为止的正文，给 CuePad 逐字显示；思考与工具参数不算，FireCode 的子代理是别的会话、不经这里。
 * 增量合并到每 `DRAFT_INTERVAL_MS` 一次，这条说完时立即补发全文；它转成工具调用、被停下或出错、下一条助手消息开始时清掉（`text: null`）。
 * 正常说完的不清：CuePad 在对话（读会话文件）里出现这一条后自己换下。`since` 是这条开始出字的时刻。
 */
export class Draft {
	private draft: { text: string; since: number } | null = null;
	/** 这条消息已转成工具调用：之后的正文不再算草稿 */
	private closed = false;
	private sentAt = 0;
	private timer: ReturnType<typeof setTimeout> | undefined;

	private readonly broadcast: (message: object) => void;

	constructor(broadcast: (message: object) => void) {
		this.broadcast = broadcast;
	}

	/** 一条新的助手消息开始了 */
	restart() {
		this.closed = false;
		this.clear();
	}

	/** 这条消息转成了工具调用 */
	close() {
		this.closed = true;
		this.clear();
	}

	/** `now`：这条说完了，不等合并的间隔 */
	grow(message: object, now = false) {
		const text = replyText(message);
		if (this.closed || !text || text === this.draft?.text) {
			if (now && this.timer) this.send();
			return;
		}
		this.draft = { text, since: this.draft?.since ?? Date.now() };
		if (now) return this.send();
		if (this.timer) return;
		const wait = this.sentAt + DRAFT_INTERVAL_MS - Date.now();
		if (wait <= 0) this.send();
		else this.timer = setTimeout(() => this.send(), wait);
	}

	clear() {
		if (!this.draft) return;
		this.draft = null;
		this.send();
	}

	/** 会话关闭：不再补发 */
	cancel() {
		clearTimeout(this.timer);
	}

	private send() {
		clearTimeout(this.timer);
		this.timer = undefined;
		this.sentAt = Date.now();
		this.broadcast({ t: "draft", text: this.draft?.text ?? null, since: this.draft?.since ?? null });
	}
}
