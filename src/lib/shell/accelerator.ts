/** 默认全局快捷键：macOS Option+Space / Windows Alt+Space，accelerator 字符串一致 */
export const DEFAULT_GLOBAL_SHORTCUT = 'Alt+Space';

export const IS_MAC = typeof navigator !== 'undefined' && navigator.userAgent.includes('Mac');

export interface KeyStroke {
	code: string;
	ctrlKey: boolean;
	altKey: boolean;
	shiftKey: boolean;
	metaKey: boolean;
}

/** 可作为全局快捷键主键的 W3C code（global-hotkey 解析器直接接受这些名字） */
const VALID_KEY_CODE =
	/^(Key[A-Z]|Digit[0-9]|F([1-9]|1[0-2])|Space|Enter|Tab|Backquote|Minus|Equal|BracketLeft|BracketRight|Backslash|Semicolon|Quote|Comma|Period|Slash|Arrow(Up|Down|Left|Right)|Home|End|PageUp|PageDown)$/;

/**
 * 按键组合 → 持久化用 W3C code accelerator 字符串。
 * 无修饰键、或主键不在允许集合（纯修饰键/Escape 等）时返回 null。
 */
export function acceleratorFromStroke(stroke: KeyStroke): string | null {
	const modifiers: string[] = [];
	if (stroke.ctrlKey) modifiers.push('Control');
	if (stroke.altKey) modifiers.push('Alt');
	if (stroke.shiftKey) modifiers.push('Shift');
	if (stroke.metaKey) modifiers.push('Super');
	if (modifiers.length === 0) return null;
	if (!VALID_KEY_CODE.test(stroke.code)) return null;
	return [...modifiers, stroke.code].join('+');
}

const MAC_MODIFIER_SYMBOLS: Record<string, string> = {
	Control: '⌃',
	Alt: '⌥',
	Shift: '⇧',
	Super: '⌘'
};

const ARROW_SYMBOLS: Record<string, string> = {
	ArrowUp: '↑',
	ArrowDown: '↓',
	ArrowLeft: '←',
	ArrowRight: '→'
};

function keyLabel(code: string): string {
	if (code.startsWith('Key')) return code.slice(3);
	if (code.startsWith('Digit')) return code.slice(5);
	return ARROW_SYMBOLS[code] ?? code;
}

/** accelerator 字符串 → 用户可读展示（mac 用符号，其余平台用 + 连接） */
export function formatAccelerator(accelerator: string, isMac = IS_MAC): string {
	const tokens = accelerator.split('+');
	const key = tokens[tokens.length - 1];
	const modifiers = tokens.slice(0, -1);
	if (isMac) {
		return `${modifiers.map((token) => MAC_MODIFIER_SYMBOLS[token] ?? token).join('')} ${keyLabel(key)}`.trim();
	}
	const winModifiers = modifiers.map((token) => (token === 'Super' ? 'Win' : token === 'Control' ? 'Ctrl' : token));
	return [...winModifiers, keyLabel(key)].join('+');
}
