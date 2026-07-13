export type SaveState = 'saving' | 'saved' | 'error';

export const AUTOSAVE_DELAY_MS = 600;

export interface AutosaveOptions<Patch extends object> {
	save: (patch: Patch) => Promise<void>;
	onState: (state: SaveState) => void;
	delayMs?: number;
}

/** 后到的字段覆盖先到的；独立函数也绕开 TS 对 `this.#x` 跨 await 的错误窄化。 */
function mergePatch<Patch extends object>(base: Patch | null, override: Patch | null): Patch | null {
	if (!base) return override;
	if (!override) return base;
	return { ...base, ...override };
}

/**
 * 单张卡片的自动保存状态机。
 *
 * - `schedule`：文本输入，停止输入 delayMs 后合并保存（debounce）。
 * - `commit`：选择类字段，立即保存。
 * - `flush`：切卡 / 退出沉浸 / 隐藏窗口前强制保存，失败不抛出。
 *
 * 串行化：同一实例永远只有一个 save 在途；在途期间新 patch 先进 buffer
 * （debounce 计时中）再进 queue（到期待写），排空循环逐个消费，杜绝并发写。
 * 失败时 patch 放回 queue 不丢，下一次 schedule/commit/flush 自动重试。
 */
export class Autosave<Patch extends object> {
	/** debounce 计时中、尚未到期的输入。 */
	#buffer: Patch | null = null;
	/** 已到期、等待写入的 patch。 */
	#queue: Patch | null = null;
	#timer: ReturnType<typeof setTimeout> | undefined;
	#draining: Promise<void> | null = null;
	readonly #save: (patch: Patch) => Promise<void>;
	readonly #onState: (state: SaveState) => void;
	readonly #delayMs: number;

	constructor(options: AutosaveOptions<Patch>) {
		this.#save = options.save;
		this.#onState = options.onState;
		this.#delayMs = options.delayMs ?? AUTOSAVE_DELAY_MS;
	}

	schedule(patch: Patch) {
		this.#buffer = mergePatch(this.#buffer, patch);
		clearTimeout(this.#timer);
		this.#timer = setTimeout(() => void this.#promote(), this.#delayMs);
	}

	commit(patch: Patch): Promise<void> {
		this.#buffer = mergePatch(this.#buffer, patch);
		return this.#promote();
	}

	flush(): Promise<void> {
		return this.#promote();
	}

	/** buffer 立即到期进入 queue，并启动（或复用）排空循环。 */
	#promote(): Promise<void> {
		clearTimeout(this.#timer);
		if (this.#buffer) {
			this.#queue = mergePatch(this.#queue, this.#buffer);
			this.#buffer = null;
		}
		this.#draining ??= this.#drain().finally(() => {
			this.#draining = null;
		});
		return this.#draining;
	}

	async #drain() {
		while (this.#queue) {
			const patch = this.#queue;
			this.#queue = null;
			this.#onState('saving');
			try {
				await this.#save(patch);
				this.#onState('saved');
			} catch {
				// 失败的 patch 放回队列（await 期间新到的字段覆盖它），保留待重试
				this.#queue = mergePatch(patch, this.#queue);
				this.#onState('error');
				return;
			}
		}
	}
}
