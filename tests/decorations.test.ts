import { describe, expect, test } from 'bun:test';
import { Text } from '@codemirror/state';
import { lastContentLine } from '../src/lib/editor/decorations';

// 分块按钮的显示条件：空行且 line.number < lastContentLine(doc)
const doc = (raw: string) => Text.of(raw.split('\n'));

describe('lastContentLine（分块按钮可见性的事实源）', () => {
	test('全空文档：无正文，任何空行都不显示按钮', () => {
		expect(lastContentLine(doc(''))).toBe(0);
		expect(lastContentLine(doc('\n\n'))).toBe(0);
	});

	test('正文末尾的空行：在最后正文之后，不显示按钮', () => {
		const document = doc('优化插件\n\n');
		expect(lastContentLine(document)).toBe(1);
		// 第 2、3 行（空行）都不小于… 均 ≥ lastContentLine 之后 → 不显示
		expect(2 < lastContentLine(document)).toBe(false);
	});

	test('正文之间的空行：下方仍有正文，显示按钮', () => {
		const document = doc('上一段\n\n下一段');
		expect(lastContentLine(document)).toBe(3);
		expect(2 < lastContentLine(document)).toBe(true);
	});

	test('分隔线不算正文：尾部 ---split--- 上方的空行不显示按钮', () => {
		expect(lastContentLine(doc('正文\n\n---split---'))).toBe(1);
		expect(lastContentLine(doc('正文\n\n---ask---\n'))).toBe(1);
	});

	test('分隔线之后还有正文：其间空行照常显示按钮', () => {
		const document = doc('正文\n\n---split---\n\n后续正文');
		expect(lastContentLine(document)).toBe(5);
		expect(4 < lastContentLine(document)).toBe(true);
	});
});
