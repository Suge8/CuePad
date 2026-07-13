import { beforeEach, describe, expect, test } from 'bun:test';

// Bun 测试环境没有 localStorage，用内存实现替代（行为等价的最小子集）
const memory = new Map<string, string>();
globalThis.localStorage = {
	getItem: (key: string) => memory.get(key) ?? null,
	setItem: (key: string, value: string) => void memory.set(key, String(value)),
	removeItem: (key: string) => void memory.delete(key),
	clear: () => memory.clear(),
	key: (index: number) => [...memory.keys()][index] ?? null,
	get length() {
		return memory.size;
	}
} as Storage;

const { clearBackup, readBackup, shouldOfferRestore, writeBackup } = await import(
	'../src/lib/editor/backup'
);

const card = { title: '标题', body: '正文', updatedAt: 1000 };

beforeEach(() => memory.clear());

describe('draft backup', () => {
	test('写入后可读回，清除后为 null', () => {
		const backup = { title: 't', body: 'b', savedAt: 42 };
		writeBackup(7, backup);
		expect(readBackup(7)).toEqual(backup);
		clearBackup(7);
		expect(readBackup(7)).toBeNull();
	});

	test('损坏的备份数据返回 null 而不是抛出', () => {
		memory.set('cuepad:draft-backup:7', '{not json');
		expect(readBackup(7)).toBeNull();
		memory.set('cuepad:draft-backup:7', '{"title":"x"}');
		expect(readBackup(7)).toBeNull();
	});

	test('备份按卡片隔离', () => {
		writeBackup(1, { title: 'a', body: null, savedAt: 1 });
		expect(readBackup(2)).toBeNull();
	});
});

describe('shouldOfferRestore', () => {
	test('无备份不提示', () => {
		expect(shouldOfferRestore(null, card)).toBe(false);
	});

	test('备份不比数据库新（等于或更旧）不提示', () => {
		expect(shouldOfferRestore({ title: '别的', body: '别的', savedAt: 1000 }, card)).toBe(false);
		expect(shouldOfferRestore({ title: '别的', body: '别的', savedAt: 999 }, card)).toBe(false);
	});

	test('备份更新但内容与数据库一致不提示', () => {
		expect(shouldOfferRestore({ title: '标题', body: '正文', savedAt: 2000 }, card)).toBe(false);
	});

	test('备份更新且正文或标题不同才提示', () => {
		expect(shouldOfferRestore({ title: '标题', body: '改过', savedAt: 2000 }, card)).toBe(true);
		expect(shouldOfferRestore({ title: '改过', body: '正文', savedAt: 2000 }, card)).toBe(true);
	});
});
