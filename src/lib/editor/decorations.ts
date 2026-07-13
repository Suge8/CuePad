import { Facet, RangeSetBuilder, StateField, type EditorState, type Text } from '@codemirror/state';
import {
	Decoration,
	EditorView,
	ViewPlugin,
	WidgetType,
	type DecorationSet,
	type ViewUpdate
} from '@codemirror/view';
import type { CardNumbering } from '$lib/db';
import { markerRole, ROLE_MARKERS, segmentLabel, SPLIT_MARKER, type SegmentRole } from './segments';
import { VARIABLE_PATTERN } from './variables';

const headingLine = Decoration.line({ class: 'cm-cue-heading' });
const listLine = Decoration.line({ class: 'cm-cue-list' });
const codeLine = Decoration.line({ class: 'cm-cue-code' });
const activeLine = Decoration.line({ class: 'cm-cue-active' });
const variableMark = Decoration.mark({ class: 'cm-cue-var' });

const HEADING_RE = /^#{1,6}\s/;
const LIST_RE = /^\s*-\s/;
const FENCE = '```';

/** 卡片编号风格，宿主经 Compartment 注入。 */
export const numberingFacet = Facet.define<CardNumbering, CardNumbering>({
	combine: (values) => values[0] ?? 'none'
});

/**
 * 所有行首 ``` 围栏行的起始偏移（升序）。
 * 用 native indexOf 扫全文字符串（非逐行 decoration 构建），百 KB 级毫秒内完成；
 * decoration 本身仍只对 viewport 构建。
 */
function scanFences(text: string): number[] {
	const fences: number[] = [];
	if (text.startsWith(FENCE)) fences.push(0);
	let from = 0;
	let at: number;
	while ((at = text.indexOf('\n' + FENCE, from)) !== -1) {
		fences.push(at + 1);
		from = at + 1;
	}
	return fences;
}

/** pos 之前的围栏行数（二分），奇数 = pos 位于未闭合围栏内。 */
function countFencesBefore(fences: number[], pos: number): number {
	let low = 0;
	let high = fences.length;
	while (low < high) {
		const mid = (low + high) >> 1;
		if (fences[mid] < pos) low = mid + 1;
		else high = mid;
	}
	return low;
}

interface MarkerInfo {
	from: number;
	to: number;
	role: SegmentRole;
	/** none → 其后段的 0-based 序号（按非空段计，与 formatSegments 编号一致）；ask/answer → 第几问（1-based）。 */
	seq: number;
}

/**
 * 最后一行真正正文（非空且非分隔线）的行号；没有则返回 0。
 * 分块按钮只在其下方还有正文的空行有意义；分隔线不算正文，
 * 否则尾部分隔线上方的空行会诱导出连续分隔符。
 */
export function lastContentLine(doc: Text): number {
	for (let number = doc.lines; number >= 1; number--) {
		const text = doc.line(number).text;
		if (text.trim() !== '' && markerRole(text) === null) return number;
	}
	return 0;
}

/** 全文分隔线行（升序）。逐行扫描，docChanged 时重建，与 scanFences 同量级。 */
function scanMarkers(doc: Text): MarkerInfo[] {
	const markers: MarkerInfo[] = [];
	let askCount = 0;
	let closedSegments = 0;
	let segmentHasText = false;
	for (let number = 1; number <= doc.lines; number++) {
		const line = doc.line(number);
		const role = markerRole(line.text);
		if (role === null) {
			if (!segmentHasText && line.text.trim() !== '') segmentHasText = true;
			continue;
		}
		if (segmentHasText) closedSegments++;
		segmentHasText = false;
		if (role === 'ask') askCount++;
		const seq = role === 'ask' || role === 'answer' ? Math.max(askCount, 1) : closedSegments;
		markers.push({ from: line.from, to: line.to, role, seq });
	}
	return markers;
}

/** 首块前无分隔线但有内容且全文已分块时，需要虚拟块头补齐编号。 */
function hasLeadContent(doc: Text, markers: MarkerInfo[]): boolean {
	if (markers.length === 0) return false;
	const firstMarkerLine = doc.lineAt(markers[0].from).number;
	for (let number = 1; number < firstMarkerLine; number++) {
		if (doc.line(number).text.trim() !== '') return true;
	}
	return false;
}

/** 首块虚拟块头：不存在于文本，点击在文档开头插入角色分隔线。 */
class LeadBadgeWidget extends WidgetType {
	constructor(readonly label: string) {
		super();
	}

	eq(other: LeadBadgeWidget) {
		return other.label === this.label;
	}

	toDOM(view: EditorView) {
		const element = document.createElement('div');
		element.className = 'cm-cue-lead';
		const label = document.createElement('span');
		label.className = 'cm-cue-divider-label';
		label.textContent = this.label;
		element.append(label);
		element.title = '点击设置首块角色';
		element.onmousedown = (event) => {
			event.preventDefault();
			// 阻止冒泡到 markerClickHandler：插入后首行已是分隔线，否则会被它再切一次
			event.stopPropagation();
			view.dispatch({ changes: { from: 0, insert: `${ROLE_MARKERS.ask}\n` } });
		};
		return element;
	}
}

/** 空行悬浮时浮现的「分块」按钮：点击把该空行替换成分隔线。 */
class SplitButtonWidget extends WidgetType {
	eq() {
		return true;
	}

	toDOM(view: EditorView) {
		const button = document.createElement('button');
		button.type = 'button';
		button.className = 'cm-cue-split-here';
		button.textContent = '＋ 分块';
		button.onmousedown = (event) => {
			event.preventDefault();
			event.stopPropagation();
			const line = view.state.doc.lineAt(view.posAtDOM(button));
			view.dispatch({ changes: { from: line.from, to: line.to, insert: SPLIT_MARKER } });
		};
		return button;
	}
}

const splitButton = Decoration.widget({ widget: new SplitButtonWidget(), side: 1 });

/**
 * 分隔线控件：光标不在该行时替换整行标记文本（live-preview 语义，
 * 光标进入即还原源文本）。点击循环切换角色，由 markerClickHandler 处理。
 */
class DividerWidget extends WidgetType {
	constructor(
		readonly label: string,
		readonly role: SegmentRole
	) {
		super();
	}

	eq(other: DividerWidget) {
		return other.label === this.label && other.role === this.role;
	}

	toDOM() {
		const element = document.createElement('span');
		element.className = 'cm-cue-divider';
		element.dataset.role = this.role;
		// 职责分离：icon 是控件（点击切角色），其余区域交给 CM 默认行为（点击放光标→还原源文本）
		const icon = document.createElement('span');
		icon.className = 'cm-cue-divider-icon';
		icon.title = '点击切换角色（普通 → 问 → 答 → 系统）';
		// 分割线图标：上下两短横，中间留缝
		icon.innerHTML =
			'<svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M2 3.8h8M2 8.2h8"/></svg>';
		element.append(icon);
		if (this.label) {
			const label = document.createElement('span');
			label.className = 'cm-cue-divider-label';
			label.textContent = this.label;
			element.append(label);
		}
		const line = document.createElement('span');
		line.className = 'cm-cue-divider-line';
		element.append(line);
		return element;
	}

	ignoreEvent() {
		return false;
	}
}

function markerBadge(marker: MarkerInfo, numbering: CardNumbering): string {
	switch (marker.role) {
		case 'ask':
			return `Q${marker.seq}`;
		case 'answer':
			return `A${marker.seq}`;
		case 'system':
			return 'SYS';
		default:
			return segmentLabel(marker.seq, numbering);
	}
}

/** 光标所在的分隔线行：显示源文本，只做淡化样式 */
const markerSourceLine = Decoration.line({ class: 'cm-cue-source' });

/** 光标所在块的正文范围；无分隔线（单块）时返回 null 不高亮。 */
function activeBlockBounds(
	doc: Text,
	markers: MarkerInfo[],
	head: number
): { from: number; to: number } | null {
	if (markers.length === 0) return null;
	let from = 0;
	let to = doc.length;
	for (const marker of markers) {
		if (marker.to < head) from = marker.to + 1;
		else if (marker.from > head) {
			to = marker.from - 1;
			break;
		} else return null; // 光标在分隔线行上
	}
	return { from, to };
}

function buildDecorations(
	view: EditorView,
	fences: number[],
	markers: MarkerInfo[],
	contentEnd: number
): DecorationSet {
	const numbering = view.state.facet(numberingFacet);
	const markerAt = new Map(markers.map((marker) => [marker.from, marker]));
	const head = view.state.selection.main.head;
	const active = activeBlockBounds(view.state.doc, markers, head);
	const cursorLine = view.state.doc.lineAt(head);
	const builder = new RangeSetBuilder<Decoration>();
	for (const range of view.visibleRanges) {
		let pos = range.from;
		while (pos <= range.to) {
			const line = view.state.doc.lineAt(pos);
			const text = line.text;
			const marker = markerAt.get(line.from);
			if (active && !marker && line.from >= active.from && line.from <= active.to) {
				builder.add(line.from, line.from, activeLine);
			}
			const inCode =
				!marker && (text.startsWith(FENCE) || countFencesBefore(fences, line.from) % 2 === 1);
			if (marker) {
				if (line.number === cursorLine.number) {
					builder.add(line.from, line.from, markerSourceLine);
				} else {
					builder.add(
						line.from,
						line.to,
						Decoration.replace({
							widget: new DividerWidget(markerBadge(marker, numbering), marker.role)
						})
					);
				}
			}
			else if (inCode) builder.add(line.from, line.from, codeLine);
			else if (HEADING_RE.test(text)) builder.add(line.from, line.from, headingLine);
			else if (LIST_RE.test(text)) builder.add(line.from, line.from, listLine);
			else if (text.trim() === '' && line.number < contentEnd)
				builder.add(line.from, line.from, splitButton);
			if (!inCode && !marker) {
				for (const match of text.matchAll(VARIABLE_PATTERN)) {
					const from = line.from + match.index;
					builder.add(from, from + match[0].length, variableMark);
				}
			}
			pos = line.to + 1;
		}
	}
	return builder.finish();
}

const decorationsPlugin = ViewPlugin.fromClass(
	class {
		decorations: DecorationSet;
		#fences: number[];
		#markers: MarkerInfo[];
		#contentEnd: number;

		constructor(view: EditorView) {
			this.#fences = scanFences(view.state.doc.toString());
			this.#markers = scanMarkers(view.state.doc);
			this.#contentEnd = lastContentLine(view.state.doc);
			this.decorations = buildDecorations(view, this.#fences, this.#markers, this.#contentEnd);
		}

		update(update: ViewUpdate) {
			if (update.docChanged) {
				this.#fences = scanFences(update.state.doc.toString());
				this.#markers = scanMarkers(update.state.doc);
				this.#contentEnd = lastContentLine(update.state.doc);
			}
			const numberingChanged =
				update.state.facet(numberingFacet) !== update.startState.facet(numberingFacet);
			if (update.docChanged || update.viewportChanged || update.selectionSet || numberingChanged) {
				this.decorations = buildDecorations(update.view, this.#fences, this.#markers, this.#contentEnd);
			}
		}
	},
	{ decorations: (plugin) => plugin.decorations }
);

/**
 * 首块虚拟块头是 block decoration（影响垂直布局），CM 禁止由 ViewPlugin 提供
 *（运行时报 “Block decorations may not be specified via plugins”），
 * 必须走 StateField → EditorView.decorations。
 */
function leadDecoration(state: EditorState): DecorationSet {
	const markers = scanMarkers(state.doc);
	if (!hasLeadContent(state.doc, markers)) return Decoration.none;
	const label = segmentLabel(0, state.facet(numberingFacet));
	// 无编号时首块不需要任何标记
	if (!label) return Decoration.none;
	return Decoration.set([
		Decoration.widget({ widget: new LeadBadgeWidget(label), side: -1, block: true }).range(0)
	]);
}

const leadBadgeField = StateField.define<DecorationSet>({
	create: leadDecoration,
	update(decorations, tr) {
		if (
			tr.docChanged ||
			tr.state.facet(numberingFacet) !== tr.startState.facet(numberingFacet)
		) {
			return leadDecoration(tr.state);
		}
		return decorations;
	},
	provide: (field) => EditorView.decorations.from(field)
});

const ROLE_CYCLE: Record<SegmentRole, SegmentRole> = {
	none: 'ask',
	ask: 'answer',
	answer: 'system',
	system: 'none'
};

/** 点击块头循环切换角色：只替换分隔线那一行文本。 */
const markerClickHandler = EditorView.domEventHandlers({
	mousedown(event, view) {
		// instanceof Element 而非 HTMLElement：点在 SVG 图形上时 target 是 SVGElement
		const target =
			event.target instanceof Element ? event.target.closest('.cm-cue-divider-icon') : null;
		if (!target) return false;
		const line = view.state.doc.lineAt(view.posAtDOM(target));
		const role = markerRole(line.text);
		if (role === null) return false;
		event.preventDefault();
		view.dispatch({
			changes: { from: line.from, to: line.to, insert: ROLE_MARKERS[ROLE_CYCLE[role]] }
		});
		return true;
	}
});

/** 视觉增强只改样式，不隐藏任何原始字符。 */
const decorationTheme = EditorView.baseTheme({
	'.cm-cue-heading': {
		fontSize: '1.3em',
		fontWeight: '600',
		letterSpacing: '-0.02em',
		lineHeight: '1.4',
		color: 'var(--color-text-strong)',
		paddingTop: '0.4em',
		paddingBottom: '0.1em'
	},
	'.cm-cue-list': {
		paddingLeft: 'calc(6px + 1.4em)',
		textIndent: '-1.15em'
	},
	'.cm-cue-code': {
		fontFamily: 'var(--font-mono)',
		fontSize: '0.86em',
		background: 'color-mix(in srgb, var(--color-text-strong) 4.5%, transparent)'
	},
	// 分隔线控件（光标不在该行）：纯虚线，有编号/角色才带小标签
	// 高度与 .cm-cue-source 严格一致（1rem + 1.2rem + 0.4rem），光标进出不跳行
	'.cm-cue-divider': {
		display: 'inline-flex',
		width: '100%',
		height: '2.6rem',
		boxSizing: 'border-box',
		alignItems: 'center',
		gap: '0.45em',
		padding: '1rem 0 0.4rem',
		verticalAlign: 'bottom'
	},
	// 控件级热区：22px 方块 + hover 底色，与正文点击区域职责分离
	'.cm-cue-divider-icon': {
		display: 'inline-grid',
		width: '22px',
		height: '22px',
		placeItems: 'center',
		flexShrink: '0',
		borderRadius: '6px',
		color: 'var(--color-text-soft)',
		opacity: '0.75',
		cursor: 'pointer',
		transition:
			'opacity var(--duration-fast) var(--ease-standard), background-color var(--duration-fast) var(--ease-standard), color var(--duration-fast) var(--ease-standard)'
	},
	'.cm-cue-divider-icon:hover': {
		opacity: '1',
		background: 'var(--color-surface-muted)',
		color: 'var(--color-text-muted)'
	},
	// 编号/角色小标签：pill 形态，角色用主题色弱底区分
	'.cm-cue-divider-label': {
		padding: '0.22em 0.6em',
		borderRadius: '999px',
		background: 'var(--color-surface-muted)',
		fontFamily: 'var(--font-mono)',
		fontSize: '0.68em',
		fontWeight: '600',
		letterSpacing: '0.08em',
		lineHeight: '1',
		color: 'var(--color-text-soft)'
	},
	'.cm-cue-divider[data-role="ask"] .cm-cue-divider-label': {
		background: 'var(--color-accent-soft)',
		color: 'var(--color-accent-text)'
	},
	'.cm-cue-divider[data-role="answer"] .cm-cue-divider-label': {
		background: 'color-mix(in srgb, var(--color-star) 16%, transparent)',
		color: 'color-mix(in srgb, var(--color-star) 72%, var(--color-text-strong))'
	},
	'.cm-cue-divider-line': {
		flex: '1',
		height: '1px',
		backgroundImage:
			'repeating-linear-gradient(to right, var(--color-border-strong) 0 5px, transparent 5px 11px)',
		opacity: '0.55',
		transition: 'opacity var(--duration-fast) var(--ease-standard)'
	},
	'.cm-cue-divider:hover .cm-cue-divider-line': {
		opacity: '1'
	},
	// 光标所在的分隔线行：还原源文本，只淡化
	'.cm-cue-source': {
		paddingTop: '1rem',
		paddingBottom: '0.4rem',
		lineHeight: '1.2rem',
		fontFamily: 'var(--font-mono)',
		fontSize: '0.72em',
		letterSpacing: '0.08em',
		color: 'var(--color-text-soft)'
	},
	// 首块虚拟编号：只在开启编号时存在
	'.cm-cue-lead': {
		padding: '0 0 0.35em',
		cursor: 'pointer'
	},
	// 空行悬浮才浮现的分块按钮；隐藏时 pointer-events 关闭，避免点空行放光标误触。
	// 绝对定位脱离文本流：否则隐形按钮占位，回车后空行光标被顶离行首
	'.cm-line:has(.cm-cue-split-here)': {
		position: 'relative'
	},
	'.cm-cue-split-here': {
		position: 'absolute',
		left: '0.1em',
		top: '50%',
		transform: 'translateY(-50%)',
		opacity: '0',
		pointerEvents: 'none',
		border: '1px dashed var(--color-border-strong)',
		borderRadius: '0.55em',
		padding: '0.05em 0.55em',
		background: 'transparent',
		color: 'var(--color-text-soft)',
		fontFamily: 'var(--font-mono)',
		fontSize: '0.68em',
		letterSpacing: '0.08em',
		lineHeight: '1.4',
		cursor: 'pointer',
		transition:
			'opacity var(--duration-fast) var(--ease-standard), color var(--duration-fast) var(--ease-standard), border-color var(--duration-fast) var(--ease-standard)',
		verticalAlign: 'middle'
	},
	'.cm-line:hover .cm-cue-split-here': {
		opacity: '1',
		pointerEvents: 'auto'
	},
	'.cm-cue-split-here:hover': {
		color: 'var(--color-accent-text)',
		borderColor: 'var(--color-accent)'
	},
	// 光标所在块：左侧 accent 细线
	'.cm-cue-active': {
		boxShadow: 'inset 2px 0 0 color-mix(in srgb, var(--color-accent) 55%, transparent)'
	},
	// {{变量}}：弱底 + 强调色内描边，与普通正文拉开层次
	'.cm-cue-var': {
		background: 'var(--color-accent-soft)',
		color: 'var(--color-accent-text)',
		boxShadow: 'inset 0 0 0 1px color-mix(in srgb, var(--color-accent) 26%, transparent)',
		borderRadius: '0.35em',
		padding: '0.05em 0.22em'
	}
});

export const cueDecorations = [decorationsPlugin, leadBadgeField, markerClickHandler, decorationTheme];
