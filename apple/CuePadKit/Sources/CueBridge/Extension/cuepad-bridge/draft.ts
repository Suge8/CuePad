import { replyText } from "./info.ts";

const DRAFT_INTERVAL_MS = 100;

/**
 * 正在说的话（`draft`）：给 CuePad 逐字显示。正常说完的不清：CuePad 在对话（读会话文件）里出现这一条后自己换下。
 * FireCode 的子代理是别的会话，不经这里。
 */
export class Draft {
	private draft: { text: string; since: number } | null = null;
	private closed = false;
	private sentAt = 0;
	private timer: ReturnType<typeof setTimeout> | undefined;

	private readonly broadcast: (message: object) => void;

	constructor(broadcast: (message: object) => void) {
		this.broadcast = broadcast;
	}

	restart() {
		this.closed = false;
		this.clear();
	}

	close() {
		this.closed = true;
		this.clear();
	}

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
