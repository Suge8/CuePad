import type { EditorState } from '@codemirror/state';
import { EditorView, keymap, type Command, type KeyBinding } from '@codemirror/view';
import { isMarkerLine, SPLIT_MARKER } from './segments';

/** 所有分隔线行的行号（1-based，升序）。文档为提示词量级，逐行扫描足够快。 */
export function markerLineNumbers(state: EditorState): number[] {
	const lines: number[] = [];
	for (let number = 1; number <= state.doc.lines; number++) {
		if (isMarkerLine(state.doc.line(number).text)) lines.push(number);
	}
	return lines;
}

/** pos 所在块的正文范围（不含两端分隔线行）。 */
export function blockRange(state: EditorState, pos: number): { from: number; to: number } {
	const line = state.doc.lineAt(pos).number;
	const markers = markerLineNumbers(state);
	let startLine = 1;
	let endLine = state.doc.lines;
	for (const marker of markers) {
		if (marker < line) {
			startLine = marker + 1;
		} else {
			endLine = marker - 1;
			break;
		}
	}
	if (startLine > endLine) {
		const at = state.doc.line(Math.min(startLine, state.doc.lines)).from;
		return { from: at, to: at };
	}
	return { from: state.doc.line(startLine).from, to: state.doc.line(endLine).to };
}

function jumpTo(view: EditorView, pos: number): boolean {
	view.dispatch({
		selection: { anchor: pos },
		effects: EditorView.scrollIntoView(pos, { y: 'center' })
	});
	return true;
}

/**
 * 下一块首行位置；无处可跳返回 null（command 回落 defaultKeymap 的文档尾）。
 * 分隔线行归属上一块（与 blockRange 一致）：光标在分隔线上时，下一块就是其后第一行。
 */
export function nextBlockStart(state: EditorState): number | null {
	const line = state.doc.lineAt(state.selection.main.head).number;
	const next = markerLineNumbers(state).find((marker) => marker >= line);
	if (next === undefined || next >= state.doc.lines) return null;
	return state.doc.line(next + 1).from;
}

/** 上一块首行位置；块内非首行先跳块首，已在块首再往上一块；无处可跳返回 null。 */
export function prevBlockStart(state: EditorState): number | null {
	const line = state.doc.lineAt(state.selection.main.head).number;
	const before = markerLineNumbers(state).filter((marker) => marker < line);
	const currentStart = (before[before.length - 1] ?? 0) + 1;
	if (line > currentStart) return state.doc.line(currentStart).from;
	if (before.length === 0) return null;
	return state.doc.line((before[before.length - 2] ?? 0) + 1).from;
}

const gotoNextBlock: Command = (view) => {
	const pos = nextBlockStart(view.state);
	return pos === null ? false : jumpTo(view, pos);
};

const gotoPrevBlock: Command = (view) => {
	const pos = prevBlockStart(view.state);
	return pos === null ? false : jumpTo(view, pos);
};

/**
 * Shift+Enter 切块的变更计算（纯函数，供 command 与测试共用）：
 * 光标前内容留在当前块，光标后内容成为新块开头；选区被分隔线替换；
 * 光标在空行上时整行变分隔线，不残留多余空行。
 */
export function splitChange(state: EditorState): {
	from: number;
	to: number;
	insert: string;
	anchor: number;
} {
	const range = state.selection.main;
	const line = state.doc.lineAt(range.from);
	if (range.empty && line.text.trim() === '') {
		// 尾行补换行；非尾行复用行尾已有的换行（anchor +1 跨过它到下一行行首）
		const atDocEnd = line.to === state.doc.length;
		const insert = atDocEnd ? `${SPLIT_MARKER}\n` : SPLIT_MARKER;
		const anchor = line.from + insert.length + (atDocEnd ? 0 : 1);
		return { from: line.from, to: line.to, insert, anchor };
	}
	const atLineStart = range.from === line.from;
	const insert = atLineStart ? `${SPLIT_MARKER}\n` : `\n${SPLIT_MARKER}\n`;
	return { from: range.from, to: range.to, insert, anchor: range.from + insert.length };
}

const splitBlockAtCursor: Command = (view) => {
	const { from, to, insert, anchor } = splitChange(view.state);
	view.dispatch({
		changes: { from, to, insert },
		selection: { anchor },
		scrollIntoView: true
	});
	return true;
};

/**
 * 块首 Backspace 合并块：前一行是分隔线时整条删除（保留一个换行），
 * 否则返回 null 回落默认 Backspace。分隔线已控件化，避免逐字符删出残缺标记。
 */
export function mergeBackwardChange(
	state: EditorState
): { from: number; to: number; anchor: number } | null {
	const range = state.selection.main;
	if (!range.empty) return null;
	const line = state.doc.lineAt(range.head);
	if (range.head !== line.from || line.number === 1) return null;
	const previous = state.doc.line(line.number - 1);
	if (!isMarkerLine(previous.text)) return null;
	if (previous.from === 0) return { from: 0, to: previous.to + 1, anchor: 0 };
	return { from: previous.from - 1, to: previous.to, anchor: previous.from };
}

/** 块尾 Delete 对称合并：下一行是分隔线时整条删除，光标不动。 */
export function mergeForwardChange(
	state: EditorState
): { from: number; to: number; anchor: number } | null {
	const range = state.selection.main;
	if (!range.empty) return null;
	const line = state.doc.lineAt(range.head);
	if (range.head !== line.to || line.number === state.doc.lines) return null;
	const next = state.doc.line(line.number + 1);
	if (!isMarkerLine(next.text)) return null;
	return { from: line.to, to: next.to, anchor: line.to };
}

function runMerge(
	view: EditorView,
	change: { from: number; to: number; anchor: number } | null
): boolean {
	if (!change) return false;
	view.dispatch({
		changes: { from: change.from, to: change.to },
		selection: { anchor: change.anchor },
		scrollIntoView: true
	});
	return true;
}

/** 块级快捷键；copyBlock 由宿主注入（剪贴板 + toast 属于应用层）。 */
export function blockKeymap(copyBlock: (text: string) => void) {
	const bindings: KeyBinding[] = [
		{ key: 'Shift-Enter', run: splitBlockAtCursor },
		{ key: 'Backspace', run: (view) => runMerge(view, mergeBackwardChange(view.state)) },
		{ key: 'Delete', run: (view) => runMerge(view, mergeForwardChange(view.state)) },
		{ key: 'Mod-ArrowDown', run: gotoNextBlock },
		{ key: 'Mod-ArrowUp', run: gotoPrevBlock },
		{
			key: 'Mod-Shift-c',
			run: (view) => {
				const { from, to } = blockRange(view.state, view.state.selection.main.head);
				copyBlock(view.state.sliceDoc(from, to));
				return true;
			}
		}
	];
	return keymap.of(bindings);
}
