import { describe, expect, test } from 'bun:test';
import { Autosave, type SaveState } from '../src/lib/editor/autosave';

type Patch = Record<string, unknown>;

interface ManualCall {
	patch: Patch;
	resolve: () => void;
	reject: (error: Error) => void;
}

function createManualHarness(delayMs = 0) {
	const states: SaveState[] = [];
	const calls: ManualCall[] = [];
	const autosave = new Autosave<Patch>({
		delayMs,
		save: (patch) =>
			new Promise<void>((resolve, reject) => calls.push({ patch, resolve, reject })),
		onState: (state) => states.push(state)
	});
	return { autosave, calls, states };
}

/** 等待微任务/宏任务排空，让 drain 循环推进（测试等待属于时序验证语义）。 */
function settle(ms = 0) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

describe('Autosave', () => {
	test('schedule 停止输入 delayMs 后才保存，且只存最后合并结果', async () => {
		const saved: Patch[] = [];
		const autosave = new Autosave<Patch>({
			delayMs: 30,
			save: async (patch) => void saved.push(patch),
			onState: () => {}
		});
		autosave.schedule({ body: 'a' });
		autosave.schedule({ body: 'ab' });
		await settle(10);
		expect(saved).toHaveLength(0);
		await settle(40);
		expect(saved).toEqual([{ body: 'ab' }]);
	});

	test('commit 立即保存并合并未到期的输入', async () => {
		const { autosave, calls } = createManualHarness(10_000);
		autosave.schedule({ body: 'draft' });
		const done = autosave.commit({ isFavorite: true });
		expect(calls).toHaveLength(1);
		expect(calls[0].patch).toEqual({ body: 'draft', isFavorite: true });
		calls[0].resolve();
		await done;
	});

	test('串行化：在途保存未完成时新 patch 只合并排队，绝不并发', async () => {
		const { autosave, calls } = createManualHarness();
		const first = autosave.commit({ a: 1 });
		expect(calls).toHaveLength(1);
		void autosave.commit({ b: 2 });
		void autosave.commit({ b: 3, c: 4 });
		expect(calls).toHaveLength(1);
		calls[0].resolve();
		await settle();
		expect(calls).toHaveLength(2);
		expect(calls[1].patch).toEqual({ b: 3, c: 4 });
		calls[1].resolve();
		await first;
	});

	test('状态转换：saving → saved；失败 → error', async () => {
		const { autosave, calls, states } = createManualHarness();
		const done = autosave.commit({ a: 1 });
		expect(states).toEqual(['saving']);
		calls[0].resolve();
		await done;
		expect(states).toEqual(['saving', 'saved']);

		const failed = autosave.commit({ b: 2 });
		calls[1].reject(new Error('disk full'));
		await failed;
		expect(states).toEqual(['saving', 'saved', 'saving', 'error']);
	});

	test('失败的 patch 不丢：flush 重试带上原内容，后到字段覆盖', async () => {
		const { autosave, calls } = createManualHarness();
		const failed = autosave.commit({ title: 'old', body: 'kept' });
		calls[0].reject(new Error('boom'));
		await failed;

		autosave.schedule({ title: 'new' });
		const retried = autosave.flush();
		expect(calls).toHaveLength(2);
		expect(calls[1].patch).toEqual({ title: 'new', body: 'kept' });
		calls[1].resolve();
		await retried;
	});

	test('flush 失败不抛出，可继续关闭流程', async () => {
		const autosave = new Autosave<Patch>({
			delayMs: 0,
			save: () => Promise.reject(new Error('offline')),
			onState: () => {}
		});
		autosave.schedule({ body: 'x' });
		await expect(autosave.flush()).resolves.toBeUndefined();
	});

	test('无待写内容时 flush 是空操作，不触发状态变化', async () => {
		const { autosave, calls, states } = createManualHarness();
		await autosave.flush();
		expect(calls).toHaveLength(0);
		expect(states).toHaveLength(0);
	});
});
