import { describe, expect, test } from 'bun:test';
import { mergePartitionOrder, reorderIds, stablePartition } from '../src/lib/workspace/reorder';
import {
	adjacentProjectId,
	parseStoredProjectId,
	resolveActiveProjectId
} from '../src/lib/workspace/view';

type Item = { id: number; active: boolean };

const items: Item[] = [
	{ id: 1, active: false },
	{ id: 2, active: true },
	{ id: 3, active: false },
	{ id: 4, active: true }
];

describe('workspace reorder', () => {
	test('stablePartition 只前置激活分区，不改变各分区基础顺序', () => {
		expect(stablePartition(items, (item) => item.active).map((item) => item.id)).toEqual([
			2, 4, 1, 3
		]);
	});

	test('mergePartitionOrder 把分区拖拽结果写回原基础槽位', () => {
		expect(mergePartitionOrder(items, [4, 2], (item) => item.active)).toEqual([1, 4, 3, 2]);
		expect(mergePartitionOrder(items, [3, 1], (item) => !item.active)).toEqual([3, 2, 1, 4]);
	});

	test('拒绝缺项、跨分区和重复 id，避免破坏基础顺序', () => {
		expect(mergePartitionOrder(items, [2], (item) => item.active)).toBeNull();
		expect(mergePartitionOrder(items, [2, 3], (item) => item.active)).toBeNull();
		expect(mergePartitionOrder(items, [2, 2], (item) => item.active)).toBeNull();
	});

	test('reorderIds 保留同列表拖拽语义', () => {
		expect(reorderIds(items, 4, 2, 'before')).toEqual([1, 4, 2, 3]);
		expect(reorderIds(items, 2, 2, 'after')).toBeNull();
		expect(reorderIds(items, 2, 4, null)).toBeNull();
	});
});

describe('active project resolution', () => {
	const projects = [
		{ id: 1, sortOrder: 0, isPinned: false },
		{ id: 2, sortOrder: 2, isPinned: true },
		{ id: 3, sortOrder: 1, isPinned: true }
	];

	test('只接受 inbox 或现存的正整数项目 id', () => {
		expect(parseStoredProjectId('inbox')).toBeNull();
		expect(parseStoredProjectId('2')).toBe(2);
		expect(parseStoredProjectId('0')).toBeUndefined();
		expect(parseStoredProjectId('2x')).toBeUndefined();
	});

	test('有效恢复值优先；失效时按未归档有卡、置顶、普通、未归档回退', () => {
		expect(resolveActiveProjectId(projects, [], 1)).toBe(1);
		expect(resolveActiveProjectId(projects, [{ projectId: null }], 99)).toBeNull();
		expect(resolveActiveProjectId(projects, [], 99)).toBe(3);
		expect(resolveActiveProjectId(projects.filter((project) => !project.isPinned), [], undefined)).toBe(1);
		expect(resolveActiveProjectId([], [], undefined)).toBeNull();
	});

	test('删除当前项目后选择展示顺序中的相邻项目', () => {
		expect(adjacentProjectId(projects, 3)).toBe(2);
		expect(adjacentProjectId(projects, 1)).toBe(2);
		expect(adjacentProjectId([{ id: 1, sortOrder: 0, isPinned: false }], 1)).toBeNull();
	});
});
