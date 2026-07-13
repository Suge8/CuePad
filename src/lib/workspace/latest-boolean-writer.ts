type WriterOptions<Result> = {
	write: (id: number, value: boolean) => Promise<Result>;
	onSuccess: (id: number, result: Result, desired: boolean) => void;
	onFailure: (id: number, persisted: boolean, error: unknown) => void;
};

type WriteState = {
	persisted: boolean;
	desired: boolean;
	done?: Promise<void>;
};

/** 同一实体串行写；在途期间只合并最新布尔意图，避免乱序响应覆盖最终状态。 */
export class LatestBooleanWriter<Result> {
	readonly #states = new Map<number, WriteState>();

	constructor(private readonly options: WriterOptions<Result>) {}

	set(id: number, persisted: boolean, desired: boolean): Promise<void> {
		const active = this.#states.get(id);
		if (active) {
			active.desired = desired;
			return active.done!;
		}

		const state: WriteState = { persisted, desired };
		this.#states.set(id, state);
		state.done = this.#drain(id, state);
		return state.done;
	}

	async #drain(id: number, state: WriteState): Promise<void> {
		try {
			while (state.persisted !== state.desired) {
				const target = state.desired;
				let result: Result;
				try {
					result = await this.options.write(id, target);
				} catch (error) {
					state.desired = state.persisted;
					this.options.onFailure(id, state.persisted, error);
					return;
				}
				state.persisted = target;
				this.options.onSuccess(id, result, state.desired);
			}
		} finally {
			this.#states.delete(id);
		}
	}
}
