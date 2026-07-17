import { describe, expect, test } from 'bun:test';
import { EditorState } from '@codemirror/state';
import {
	blockRange,
	markerLineNumbers,
	mergeBackwardChange,
	mergeForwardChange,
	nextBlockStart,
	prevBlockStart,
	splitChange
} from '../src/lib/editor/blocks';
import { SPLIT_MARKER } from '../src/lib/editor/segments';

function state(doc: string, anchor?: number, head?: number): EditorState {
	return EditorState.create({
		doc,
		selection: anchor === undefined ? undefined : { anchor, head }
	});
}

/** 应用 splitChange 后的文档与光标位置。 */
function applySplit(doc: string, anchor: number, head?: number): { doc: string; cursor: number } {
	const before = state(doc, anchor, head);
	const { from, to, insert, anchor: cursor } = splitChange(before);
	return { doc: doc.slice(0, from) + insert + doc.slice(to), cursor };
}

describe('markerLineNumbers', () => {
	test('识别全部四种分隔线行号', () => {
		const doc = `a\n${SPLIT_MARKER}\nb\n---ask---\nc\n---answer---\nd\n---system---\ne`;
		expect(markerLineNumbers(state(doc))).toEqual([2, 4, 6, 8]);
	});

	test('无分隔线返回空数组', () => {
		expect(markerLineNumbers(state('a\nb'))).toEqual([]);
	});
});

describe('blockRange', () => {
	const doc = `第一块\n${SPLIT_MARKER}\n第二块首\n第二块尾\n${SPLIT_MARKER}\n第三块`;
	// UTF-16 偏移：第一块 [0,3]，marker [4,15]，第二块 [16,25]，marker [26,37]，第三块 [38,41]

	test('首块范围', () => {
		expect(blockRange(state(doc), 0)).toEqual({ from: 0, to: 3 });
	});

	test('中间块跨多行', () => {
		const range = blockRange(state(doc), 18);
		expect(state(doc).sliceDoc(range.from, range.to)).toBe('第二块首\n第二块尾');
	});

	test('末块范围到文档尾', () => {
		const range = blockRange(state(doc), 39);
		expect(state(doc).sliceDoc(range.from, range.to)).toBe('第三块');
	});

	test('光标在分隔线行时归属上一块', () => {
		const markerPos = doc.indexOf(SPLIT_MARKER);
		expect(blockRange(state(doc), markerPos)).toEqual({ from: 0, to: 3 });
	});

	test('单块（无分隔线）覆盖全文', () => {
		expect(blockRange(state('a\nb'), 2)).toEqual({ from: 0, to: 3 });
	});
});

describe('nextBlockStart / prevBlockStart（Cmd+↑/↓ 跳块）', () => {
	const doc = `第一块\n${SPLIT_MARKER}\n第二块\n${SPLIT_MARKER}\n第三块`;
	// UTF-16 偏移：第一块 [0,3]，marker [4,15]，第二块 [16,19]，marker [20,31]，第三块 [32,35]

	test('块正文 → 下一块首行', () => {
		expect(nextBlockStart(state(doc, 1))).toBe(16);
		expect(nextBlockStart(state(doc, 17))).toBe(32);
	});

	test('光标在分隔线行 → 紧随其后的块，不跳过', () => {
		expect(nextBlockStart(state(doc, 4))).toBe(16);
		expect(nextBlockStart(state(doc, 20))).toBe(32);
	});

	test('末块无处可跳 → null（回落文档尾）', () => {
		expect(nextBlockStart(state(doc, 33))).toBeNull();
	});

	test('块内非首行先跳块首，块首再往上一块', () => {
		const multiline = `第一块\n${SPLIT_MARKER}\n第二块首\n第二块尾`;
		// 第二块尾（pos 21+）→ 第二块首（pos 16）→ 第一块首（pos 0）
		expect(prevBlockStart(state(multiline, 22))).toBe(16);
		expect(prevBlockStart(state(multiline, 16))).toBe(0);
	});

	test('首块块首无处可跳 → null（回落文档首）', () => {
		expect(prevBlockStart(state(doc, 0))).toBeNull();
	});

	test('光标在分隔线行 → 上一块块首（分隔线归属上一块）', () => {
		expect(prevBlockStart(state(doc, 4))).toBe(0);
		expect(prevBlockStart(state(doc, 20))).toBe(16);
	});
});

describe('splitChange（Shift+Enter 切块）', () => {
	test('行中切块：光标后内容成为新块开头', () => {
		const { doc, cursor } = applySplit('abc', 1);
		expect(doc).toBe(`a\n${SPLIT_MARKER}\nbc`);
		expect(doc.slice(cursor)).toBe('bc');
	});

	test('非空行行首切块：整行推入新块，不多插空行', () => {
		const { doc, cursor } = applySplit('abc', 0);
		expect(doc).toBe(`${SPLIT_MARKER}\nabc`);
		expect(doc.slice(cursor)).toBe('abc');
	});

	test('空行上切块：整行变分隔线，不残留空行', () => {
		const { doc, cursor } = applySplit('a\n\nb', 2);
		expect(doc).toBe(`a\n${SPLIT_MARKER}\nb`);
		expect(doc.slice(cursor)).toBe('b');
	});

	test('文档尾切块：光标落在新空块', () => {
		const { doc, cursor } = applySplit('a', 1);
		expect(doc).toBe(`a\n${SPLIT_MARKER}\n`);
		expect(cursor).toBe(doc.length);
	});

	test('选区被分隔线替换', () => {
		const { doc, cursor } = applySplit('abcdef', 1, 5);
		expect(doc).toBe(`a\n${SPLIT_MARKER}\nf`);
		expect(doc.slice(cursor)).toBe('f');
	});
});

describe('mergeBackwardChange（块首 Backspace 合并块）', () => {
	// `a\n---split---\nb`：a=0，\n=1，marker=[2,13]，\n=13，b=14
	const doc = `a\n${SPLIT_MARKER}\nb`;

	function applyMerge(change: { from: number; to: number } | null, source: string): string | null {
		if (!change) return null;
		return source.slice(0, change.from) + source.slice(change.to);
	}

	test('光标在分隔线后块首：删除整条分隔线，保留一个换行', () => {
		const change = mergeBackwardChange(state(doc, 14));
		expect(applyMerge(change, doc)).toBe('a\nb');
		expect(change?.anchor).toBe(2);
	});

	test('分隔线是文档首行：删除分隔线与其换行', () => {
		const headDoc = `${SPLIT_MARKER}\nb`;
		const change = mergeBackwardChange(state(headDoc, 12));
		expect(applyMerge(change, headDoc)).toBe('b');
		expect(change?.anchor).toBe(0);
	});

	test('前一行不是分隔线：回落默认（null）', () => {
		expect(mergeBackwardChange(state('a\nb', 2))).toBeNull();
	});

	test('光标不在行首：回落默认', () => {
		expect(mergeBackwardChange(state(doc, 15))).toBeNull();
	});

	test('非空选区：回落默认', () => {
		expect(mergeBackwardChange(state(doc, 14, 15))).toBeNull();
	});

	test('连续分隔线：一次只删最近一条', () => {
		const multi = `a\n${SPLIT_MARKER}\n---ask---\nb`;
		const change = mergeBackwardChange(state(multi, 24));
		expect(applyMerge(change, multi)).toBe(`a\n${SPLIT_MARKER}\nb`);
	});
});

describe('mergeForwardChange（块尾 Delete 合并块）', () => {
	const doc = `a\n${SPLIT_MARKER}\nb`;

	function applyMerge(change: { from: number; to: number } | null, source: string): string | null {
		if (!change) return null;
		return source.slice(0, change.from) + source.slice(change.to);
	}

	test('光标在分隔线前块尾：删除整条分隔线，光标不动', () => {
		const change = mergeForwardChange(state(doc, 1));
		expect(applyMerge(change, doc)).toBe('a\nb');
		expect(change?.anchor).toBe(1);
	});

	test('分隔线是文档末行：删除换行与分隔线', () => {
		const tailDoc = `a\n${SPLIT_MARKER}`;
		const change = mergeForwardChange(state(tailDoc, 1));
		expect(applyMerge(change, tailDoc)).toBe('a');
	});

	test('下一行不是分隔线：回落默认', () => {
		expect(mergeForwardChange(state('a\nb', 1))).toBeNull();
	});

	test('光标不在行尾：回落默认', () => {
		expect(mergeForwardChange(state(doc, 0))).toBeNull();
	});
});
