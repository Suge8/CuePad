import { describe, expect, test } from 'bun:test';
import { LatestBooleanWriter } from '../src/lib/workspace/latest-boolean-writer';
import { mergePersistedPatch } from '../src/lib/workspace/merge-persisted';

function deferred<Value>() {
	let resolve!: (value: Value) => void;
	const promise = new Promise<Value>((done) => (resolve = done));
	return { promise, resolve };
}

describe('LatestBooleanWriter', () => {
	test('同一实体串行写入，并让快速双切的最终意图胜出', async () => {
		const first = deferred<{ saved: boolean }>();
		const second = deferred<{ saved: boolean }>();
		const secondStarted = deferred<void>();
		const writes: boolean[] = [];
		const settled: [boolean, boolean][] = [];
		const writer = new LatestBooleanWriter({
			write: (_id, value) => {
				writes.push(value);
				if (writes.length === 2) secondStarted.resolve();
				return writes.length === 1 ? first.promise : second.promise;
			},
			onSuccess: (_id, result, desired) => settled.push([result.saved, desired]),
			onFailure: () => undefined
		});

		const firstDone = writer.set(7, false, true);
		const finalDone = writer.set(7, true, false);
		expect(writes).toEqual([true]);

		first.resolve({ saved: true });
		await secondStarted.promise;
		expect(writes).toEqual([true, false]);
		expect(settled[0]).toEqual([true, false]);

		second.resolve({ saved: false });
		await Promise.all([firstDone, finalDone]);
		expect(settled).toEqual([
			[true, false],
			[false, false]
		]);
	});

	test('延迟响应只提交布尔字段，不覆盖请求期间更新的正文与顺序', async () => {
		type CardState = {
			body: string;
			sortOrder: number;
			isFavorite: boolean;
			updatedAt: number;
		};
		const response = deferred<CardState>();
		let current: CardState = {
			body: '旧正文',
			sortOrder: 0,
			isFavorite: false,
			updatedAt: 10
		};
		const writer = new LatestBooleanWriter({
			write: () => response.promise,
			onSuccess: (_id, persisted, desired) => {
				current = mergePersistedPatch(current, persisted, { isFavorite: desired });
			},
			onFailure: () => undefined
		});

		const done = writer.set(5, false, true);
		current = { ...current, body: '新正文', sortOrder: 8, updatedAt: 30 };
		response.resolve({ body: '旧正文', sortOrder: 0, isFavorite: true, updatedAt: 20 });
		await done;

		expect(current).toEqual({
			body: '新正文',
			sortOrder: 8,
			isFavorite: true,
			updatedAt: 30
		});
	});

	test('写入失败回滚到最后一次已持久值', async () => {
		const failures: [boolean, string][] = [];
		const writer = new LatestBooleanWriter({
			write: () => Promise.reject(new Error('disk full')),
			onSuccess: () => undefined,
			onFailure: (_id, persisted, error) =>
				failures.push([persisted, error instanceof Error ? error.message : String(error)])
		});

		await writer.set(3, false, true);
		expect(failures).toEqual([[false, 'disk full']]);
	});
});
