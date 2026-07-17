import { describe, expect, test } from 'bun:test';
import {
	firstContentLine,
	formatSegments,
	parseSegments,
	segmentLabel,
	SPLIT_MARKER,
	trimSegment
} from '../src/lib/editor/segments';

function texts(input: string): string[] {
	return parseSegments(input).map((segment) => segment.text);
}

describe('parseSegments', () => {
	test('无分隔符时整篇为一段，逐字保留', () => {
		const text = '第一行\n\n  缩进行\t\n结尾';
		expect(parseSegments(text)).toEqual([{ text }]);
	});

	test('空文本得到一个空段', () => {
		expect(parseSegments('')).toEqual([{ text: '' }]);
	});

	test('单个分隔符切成两段，分段不含分隔符', () => {
		expect(texts(`前文\n${SPLIT_MARKER}\n后文`)).toEqual(['前文', '后文']);
	});

	test('多个分隔符依次切分', () => {
		expect(texts(`a\n${SPLIT_MARKER}\nb\n${SPLIT_MARKER}\nc`)).toEqual(['a', 'b', 'c']);
	});

	test('分隔符行首尾带空白（trim 后相等）仍算分隔', () => {
		expect(texts(`a\n  ${SPLIT_MARKER}\t \nb`)).toEqual(['a', 'b']);
	});

	test('非独占行的分隔符文本不误切', () => {
		const inline = `前缀 ${SPLIT_MARKER}\n${SPLIT_MARKER} 后缀\nx${SPLIT_MARKER}x`;
		expect(texts(inline)).toEqual([inline]);
	});

	test('形近但不相等的行不算分隔符', () => {
		const text = `a\n----split----\n---SPLIT---\nb`;
		expect(texts(text)).toEqual([text]);
	});

	test('保留段内空行与行尾空格', () => {
		const first = '开头\n\n  中间有空行  \n';
		const second = '\n结尾前有空行';
		expect(texts(`${first}\n${SPLIT_MARKER}\n${second}`)).toEqual([first, second]);
	});

	test('分隔符在开头/结尾产生空段', () => {
		expect(texts(`${SPLIT_MARKER}\n正文\n${SPLIT_MARKER}`)).toEqual(['', '正文', '']);
	});

	test('历史角色标记宽容解析为普通分隔线（旧数据兼容）', () => {
		expect(texts(`背景\n---ask---\n问题\n---answer---\n回答`)).toEqual(['背景', '问题', '回答']);
		expect(texts(`---system---\n你是助手\n${SPLIT_MARKER}\n正文`)).toEqual(['', '你是助手', '正文']);
	});
});

describe('segmentLabel', () => {
	test('decimal / alpha / cjk / none', () => {
		expect(segmentLabel(0, 'decimal')).toBe('1');
		expect(segmentLabel(0, 'alpha')).toBe('A');
		expect(segmentLabel(25, 'alpha')).toBe('Z');
		expect(segmentLabel(26, 'alpha')).toBe('AA');
		expect(segmentLabel(0, 'cjk')).toBe('一');
		expect(segmentLabel(9, 'cjk')).toBe('十');
		expect(segmentLabel(11, 'cjk')).toBe('十二');
		expect(segmentLabel(20, 'cjk')).toBe('二十一');
		expect(segmentLabel(0, 'none')).toBe('');
	});
});

describe('firstContentLine', () => {
	test('跳过分隔线行，marker 开头的卡片预览不显示标记', () => {
		expect(firstContentLine(`---ask---\n问题正文`)).toBe('问题正文');
		expect(firstContentLine(`\n${SPLIT_MARKER}\n\n正文`)).toBe('正文');
	});

	test('无正文行返回空串', () => {
		expect(firstContentLine('')).toBe('');
		expect(firstContentLine(`---ask---\n\n`)).toBe('');
	});
});

describe('trimSegment', () => {
	test('去首尾空行，保留段内空行与缩进', () => {
		expect(trimSegment('\n\n  a\n\n  b  \n\n')).toBe('a\n\n  b');
	});
});

describe('formatSegments', () => {
	test('单个普通段纯 trim 返回，不加头', () => {
		expect(formatSegments('\n正文\n\n', 'decimal')).toBe('正文');
	});

	test('空段丢弃，全空返回空串', () => {
		expect(formatSegments(`\n${SPLIT_MARKER}\n  \n`, 'decimal')).toBe('');
	});

	test('decimal 编号注入普通段头', () => {
		expect(formatSegments(`a\n${SPLIT_MARKER}\nb`, 'decimal')).toBe('## 1\na\n\n## 2\nb');
	});

	test('alpha 编号', () => {
		expect(formatSegments(`a\n${SPLIT_MARKER}\nb`, 'alpha')).toBe('## A\na\n\n## B\nb');
	});

	test('numbering none 时段间用 --- 分隔', () => {
		expect(formatSegments(`a\n${SPLIT_MARKER}\nb`, 'none')).toBe('a\n\n---\n\nb');
	});

	test('历史角色标记按普通分隔线排版（旧数据兼容）', () => {
		const text = `---ask---\n问一\n---answer---\n答一`;
		expect(formatSegments(text, 'none')).toBe('问一\n\n---\n\n答一');
		expect(formatSegments(text, 'decimal')).toBe('## 1\n问一\n\n## 2\n答一');
	});
});
