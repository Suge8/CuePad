import type { CardNumbering } from '$lib/db';

export const SPLIT_MARKER = '---split---';

/** 分隔线定义其后一段的角色；第一段（无分隔线）恒为 none。 */
export type SegmentRole = 'none' | 'ask' | 'answer' | 'system';

const MARKER_ROLES: Record<string, SegmentRole> = {
	[SPLIT_MARKER]: 'none',
	'---ask---': 'ask',
	'---answer---': 'answer',
	'---system---': 'system'
};

export const ROLE_MARKERS: Record<SegmentRole, string> = {
	none: SPLIT_MARKER,
	ask: '---ask---',
	answer: '---answer---',
	system: '---system---'
};

/** 独占一行且 trim 后严格等于某个分隔标记时返回其角色，否则 null。 */
export function markerRole(lineText: string): SegmentRole | null {
	return MARKER_ROLES[lineText.trim()] ?? null;
}

export interface Segment {
	role: SegmentRole;
	text: string;
}

/** 首个非分隔线的非空行；卡片预览/标题兜底用，避免把 `---ask---` 当正文展示。 */
export function firstContentLine(text: string): string {
	return text.split('\n').find((line) => line.trim() && markerRole(line) === null) ?? '';
}

/**
 * 按分隔线切分正文。分段不含分隔线本身，段内空白（空行、行尾空格）原样保留。
 */
export function parseSegments(text: string): Segment[] {
	const segments: Segment[] = [];
	let current: string[] = [];
	let role: SegmentRole = 'none';
	for (const line of text.split('\n')) {
		const next = markerRole(line);
		if (next === null) {
			current.push(line);
			continue;
		}
		segments.push({ role, text: current.join('\n') });
		current = [];
		role = next;
	}
	segments.push({ role, text: current.join('\n') });
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
 * - 角色段头：ask → `## Q<n>`（n 为第几问），answer → `## A<n>`（跟随最近的问），system → `## System`
 * - 普通段按 numbering 注入 `## <编号>`；numbering 为 none 时段间用 `---` 分隔
 * - 单个普通段不加任何头，纯 trim 返回
 */
export function formatSegments(text: string, numbering: CardNumbering): string {
	const segments = parseSegments(text)
		.map((segment) => ({ ...segment, text: trimSegment(segment.text) }))
		.filter((segment) => segment.text !== '');
	if (segments.length === 0) return '';
	if (segments.length === 1 && segments[0].role === 'none') return segments[0].text;

	let askCount = 0;
	const parts = segments.map((segment, index) => {
		let heading = '';
		if (segment.role === 'ask') heading = `## Q${++askCount}`;
		else if (segment.role === 'answer') heading = `## A${Math.max(askCount, 1)}`;
		else if (segment.role === 'system') heading = '## System';
		else if (numbering !== 'none') heading = `## ${segmentLabel(index, numbering)}`;

		if (heading) return `${heading}\n${segment.text}`;
		return index === 0 ? segment.text : `---\n\n${segment.text}`;
	});
	return parts.join('\n\n');
}
