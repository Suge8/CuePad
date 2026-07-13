import { describe, expect, test } from 'bun:test';
import {
	acceleratorFromStroke,
	DEFAULT_GLOBAL_SHORTCUT,
	formatAccelerator,
	type KeyStroke
} from '../src/lib/shell/accelerator';

function stroke(code: string, modifiers: Partial<KeyStroke> = {}): KeyStroke {
	return { code, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...modifiers };
}

describe('acceleratorFromStroke', () => {
	test('default shortcut round-trips (Option/Alt + Space)', () => {
		expect(acceleratorFromStroke(stroke('Space', { altKey: true }))).toBe(DEFAULT_GLOBAL_SHORTCUT);
	});

	test('joins modifiers in a stable order', () => {
		expect(
			acceleratorFromStroke(stroke('KeyK', { ctrlKey: true, altKey: true, shiftKey: true, metaKey: true }))
		).toBe('Control+Alt+Shift+Super+KeyK');
	});

	test('meta maps to Super (Command on macOS, Win key elsewhere)', () => {
		expect(acceleratorFromStroke(stroke('KeyP', { metaKey: true }))).toBe('Super+KeyP');
	});

	test('rejects keys without any modifier', () => {
		expect(acceleratorFromStroke(stroke('KeyA'))).toBeNull();
	});

	test('rejects modifier-only strokes', () => {
		expect(acceleratorFromStroke(stroke('AltLeft', { altKey: true }))).toBeNull();
		expect(acceleratorFromStroke(stroke('MetaLeft', { metaKey: true }))).toBeNull();
	});

	test('rejects unsupported main keys such as Escape', () => {
		expect(acceleratorFromStroke(stroke('Escape', { ctrlKey: true }))).toBeNull();
	});

	test('accepts digits, function keys, and arrows', () => {
		expect(acceleratorFromStroke(stroke('Digit3', { ctrlKey: true }))).toBe('Control+Digit3');
		expect(acceleratorFromStroke(stroke('F6', { shiftKey: true }))).toBe('Shift+F6');
		expect(acceleratorFromStroke(stroke('ArrowUp', { altKey: true }))).toBe('Alt+ArrowUp');
	});
});

describe('formatAccelerator', () => {
	test('uses mac symbols without separators', () => {
		expect(formatAccelerator('Alt+Space', true)).toBe('⌥ Space');
		expect(formatAccelerator('Control+Shift+Super+KeyK', true)).toBe('⌃⇧⌘ K');
	});

	test('uses plus-joined names elsewhere', () => {
		expect(formatAccelerator('Alt+Space', false)).toBe('Alt+Space');
		expect(formatAccelerator('Control+Super+Digit3', false)).toBe('Ctrl+Win+3');
	});
});
