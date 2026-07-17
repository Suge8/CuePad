import type { CardNumbering } from '$lib/db';

export const SPLIT_MARKER = '---split---';

/** 历史版本的角色分隔线；宽容解析为普通分隔线，旧数据不迁移也不炸。 */
const LEGACY_MARKERS = new Set(['---ask---', '---answer---', '---system---']);

/** 独占一行且 trim 后是分隔标记（含历史角色标记）时为分隔线行。 */
export function isMarkerLine(lineText: string): boolean {
	const trimmed = lineText.trim();
	return trimmed === SPLIT_MARKER || LEGACY_MARKERS.has(trimmed);
}

export interface Segment {
	text: string;
}

/** 首个非分隔线的非空行；卡片预览/标题兜底用，避免把分隔标记当正文展示。 */
export function firstContentLine(text: string): string {
	return text.split('\n').find((line) => line.trim() && !isMarkerLine(line)) ?? '';
}

/**
 * 按分隔线切分正文。分段不含分隔线本身，段内空白（空行、行尾空格）原样保留。
 */
export function parseSegments(text: string): Segment[] {
	const segments: Segment[] = [];
	let current: string[] = [];
	for (const line of text.split('\n')) {
		if (!isMarkerLine(line)) {
			current.push(line);
			continue;
		}
		segments.push({ text: current.join('\n') });
		current = [];
	}
	segments.push({ text: current.join('\n') });
	return segments;
}

const CJK_DIGITS = ['', '一', '二', '三', '四', '五', '六', '七', '八', '九'];

function cjkNumber(value: number): string {
	if (value > 99) return String(value);
	const tens = Math.floor(value / 10);
	const ones = value % 10;
	if (tens === 0) return CJK_DIGITS[ones];
	return `${tens === 1 ? '' : CJK_DIGITS[tens]}十${CJK_DIGITS[ones]}`;
}

function alphaNumber(value: number): string {
	let label = '';
	while (value > 0) {
		value -= 1;
		label = String.fromCharCode(65 + (value % 26)) + label;
		value = Math.floor(value / 26);
	}
	return label;
}

/** 第 index 段（0-based）的编号文本；numbering 为 none 时返回空串。 */
export function segmentLabel(index: number, numbering: CardNumbering): string {
	const ordinal = index + 1;
	switch (numbering) {
		case 'decimal':
			return String(ordinal);
		case 'alpha':
			return alphaNumber(ordinal);
		case 'cjk':
			return cjkNumber(ordinal);
		default:
			return '';
	}
}

/** 去掉段首尾空行与两端空白，段内格式不动。 */
export function trimSegment(text: string): string {
	return text.replace(/^[ \t]*\n+/, '').replace(/\n+[ \t]*$/, '').trim();
}

/**
 * 复制排版（确定性规则，无 LLM）：
 * - 每段 trim 首尾空行，空段丢弃
 * - 开启编号时按 numbering 注入 `## <编号>` 段头；无编号时段间用 `---` 分隔
 * - 单段不加任何头，纯 trim 返回
 */
export function formatSegments(text: string, numbering: CardNumbering): string {
	const segments = parseSegments(text)
		.map((segment) => trimSegment(segment.text))
		.filter((segment) => segment !== '');
	if (segments.length === 0) return '';
	if (segments.length === 1) return segments[0];

	const parts = segments.map((segment, index) => {
		if (numbering !== 'none') return `## ${segmentLabel(index, numbering)}\n${segment}`;
		return index === 0 ? segment : `---\n\n${segment}`;
	});
	return parts.join('\n\n');
}
