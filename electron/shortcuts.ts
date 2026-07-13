import { globalShortcut } from 'electron';

const MODIFIERS = new Set(['Control', 'Alt', 'Shift', 'Super']);
const KEY_CODES: Record<string, string> = {
	Space: 'Space',
	Enter: 'Enter',
	Tab: 'Tab',
	Backquote: '`',
	Minus: '-',
	Equal: '=',
	BracketLeft: '[',
	BracketRight: ']',
	Backslash: '\\',
	Semicolon: ';',
	Quote: "'",
	Comma: ',',
	Period: '.',
	Slash: '/',
	ArrowUp: 'Up',
	ArrowDown: 'Down',
	ArrowLeft: 'Left',
	ArrowRight: 'Right',
	Home: 'Home',
	End: 'End',
	PageUp: 'PageUp',
	PageDown: 'PageDown'
};

function electronKey(code: string): string | null {
	if (/^Key[A-Z]$/.test(code)) return code.slice(3);
	if (/^Digit[0-9]$/.test(code)) return code.slice(5);
	if (/^F([1-9]|1[0-2])$/.test(code)) return code;
	return KEY_CODES[code] ?? null;
}

export function toElectronAccelerator(accelerator: string): string {
	const tokens = accelerator.split('+');
	const code = tokens.pop();
	const key = code && electronKey(code);
	if (!key || tokens.length === 0 || tokens.some((token) => !MODIFIERS.has(token))) {
		throw new Error(`不支持的全局快捷键：${accelerator}`);
	}
	return [...tokens, key].join('+');
}

export function registerShortcut(accelerator: string, onTrigger: () => void): void {
	const electronAccelerator = toElectronAccelerator(accelerator);
	if (!globalShortcut.register(electronAccelerator, onTrigger)) {
		throw new Error(`全局快捷键已被占用：${accelerator}`);
	}
}

export function unregisterShortcut(accelerator: string): void {
	globalShortcut.unregister(toElectronAccelerator(accelerator));
}

export function isShortcutRegistered(accelerator: string): boolean {
	return globalShortcut.isRegistered(toElectronAccelerator(accelerator));
}

export function unregisterAllShortcuts(): void {
	globalShortcut.unregisterAll();
}
