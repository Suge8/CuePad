import { describe, expect, test } from 'bun:test';
import { createLatestWins } from '../src/lib/latest-wins';

describe('createLatestWins', () => {
	test('旧请求乱序返回时不再是最新，不能写回状态', async () => {
		const guard = createLatestWins();
		let tags: string[] = [];

		const load = async (ticket: number, result: string[], delayMs: number) => {
			await new Promise((resolve) => setTimeout(resolve, delayMs));
			if (guard.isCurrent(ticket)) tags = result;
		};

		// A 先发但后返回（模拟慢请求），B 后发先返回
		const ticketA = guard.next();
		const slow = load(ticketA, ['tag-of-A'], 30);
		const ticketB = guard.next();
		const fast = load(ticketB, ['tag-of-B'], 1);

		await Promise.all([slow, fast]);
		expect(tags).toEqual(['tag-of-B']);
	});

	test('票据 + 目标校验组合：deselect（目标漂移）后旧请求不得写回', async () => {
		// 复刻 store.selectCard 的守卫合同：写回需同时满足「票据最新」与「目标仍是当前选中」
		const guard = createLatestWins();
		let currentId: number | null = 1;
		let tags: string[] = [];

		const ticket = guard.next();
		const slowLoad = (async () => {
			await new Promise((resolve) => setTimeout(resolve, 10));
			if (guard.isCurrent(ticket) && currentId === 1) tags = ['tag-of-1'];
		})();

		// 请求在途时 deselect：不领新票（无新加载），只改目标；tags 保持初始空态
		currentId = null;

		await slowLoad;
		expect(tags).toEqual([]); // 票据虽仍最新，目标已漂移，不得写回
	});

	test('顺序请求正常生效', async () => {
		const guard = createLatestWins();
		let value = 0;
		const first = guard.next();
		if (guard.isCurrent(first)) value = 1;
		const second = guard.next();
		expect(guard.isCurrent(first)).toBe(false);
		if (guard.isCurrent(second)) value = 2;
		expect(value).toBe(2);
	});
});
