import { readFileSync } from 'node:fs';
import { expect, mock, test } from 'bun:test';

const registered = new Map<string, () => void>();
let menuTemplate: { label: string; click: () => void }[] = [];
let trayImagePath = '';
const image = {
	isEmpty: () => false,
	setTemplateImage: (value: boolean) => {
		image.template = value;
	},
	template: false
};

class FakeTray {
	tooltip = '';
	menu: unknown;

	constructor(readonly trayImage: unknown) {}

	setToolTip(value: string) {
		this.tooltip = value;
	}

	setContextMenu(value: unknown) {
		this.menu = value;
	}
}

mock.module('electron', () => ({
	app: { getAppPath: () => '/Applications/CuePad' },
	globalShortcut: {
		register: (accelerator: string, callback: () => void) => {
			if (registered.has(accelerator)) return false;
			registered.set(accelerator, callback);
			return true;
		},
		unregister: (accelerator: string) => registered.delete(accelerator),
		unregisterAll: () => registered.clear(),
		isRegistered: (accelerator: string) => registered.has(accelerator)
	},
	Menu: {
		buildFromTemplate: (template: typeof menuTemplate) => {
			menuTemplate = template;
			return template;
		}
	},
	nativeImage: {
		createFromPath: (imagePath: string) => {
			trayImagePath = imagePath;
			return image;
		}
	},
	Tray: FakeTray
}));

const {
	isShortcutRegistered,
	registerShortcut,
	toElectronAccelerator,
	unregisterAllShortcuts,
	unregisterShortcut
} = await import('../electron/shortcuts');
const { createTray } = await import('../electron/tray');

function pngSize(filename: string) {
	const image = readFileSync(new URL(`../electron/assets/${filename}`, import.meta.url));
	return { width: image.readUInt32BE(16), height: image.readUInt32BE(20) };
}

test('托盘资源以 22pt + 2x Retina 密度提供', () => {
	expect(pngSize('trayTemplate.png')).toEqual({ width: 22, height: 22 });
	expect(pngSize('trayTemplate@2x.png')).toEqual({ width: 44, height: 44 });
});

test('W3C accelerator 转为 Electron accelerator', () => {
	expect(toElectronAccelerator('Alt+Space')).toBe('Alt+Space');
	expect(toElectronAccelerator('Control+Alt+KeyU')).toBe('Control+Alt+U');
	expect(toElectronAccelerator('Shift+Digit5')).toBe('Shift+5');
	expect(toElectronAccelerator('Super+ArrowUp')).toBe('Super+Up');
	expect(toElectronAccelerator('Control+F12')).toBe('Control+F12');
	expect(toElectronAccelerator('Control+BracketLeft')).toBe('Control+[');
	expect(toElectronAccelerator('Alt+Quote')).toBe("Alt+'");
});

test('accelerator codec 拒绝无修饰键和不支持的主键', () => {
	for (const accelerator of ['KeyU', 'Control+Escape']) {
		let message = '';
		try {
			toElectronAccelerator(accelerator);
		} catch (error) {
			message = String(error);
		}
		expect(message).toContain('不支持的全局快捷键');
	}
});

test('主进程注册表固定使用同一个 toggle handler', () => {
	let triggers = 0;
	registerShortcut('Control+Alt+KeyU', () => {
		triggers += 1;
	});
	expect(isShortcutRegistered('Control+Alt+KeyU')).toBe(true);
	registered.get('Control+Alt+U')?.();
	expect(triggers).toBe(1);
	let duplicateError = '';
	try {
		registerShortcut('Control+Alt+KeyU', () => undefined);
	} catch (error) {
		duplicateError = String(error);
	}
	expect(duplicateError).toContain('已被占用');
	unregisterShortcut('Control+Alt+KeyU');
	expect(isShortcutRegistered('Control+Alt+KeyU')).toBe(false);
	unregisterAllShortcuts();
});

test('托盘使用模板图并提供等价菜单', () => {
	const calls: string[] = [];
	const tray = createTray({
		toggle: () => calls.push('toggle'),
		openSettings: () => calls.push('settings'),
		quit: () => calls.push('quit')
	}) as unknown as FakeTray;

	expect(tray instanceof FakeTray).toBe(true);
	expect(trayImagePath.endsWith('/electron/assets/trayTemplate.png')).toBe(true);
	expect(image.template).toBe(true);
	expect(tray.tooltip).toBe('CuePad');
	expect(menuTemplate.map((item) => item.label)).toEqual(['显示 / 隐藏', '设置', '退出 CuePad']);
	menuTemplate.forEach((item) => item.click());
	expect(calls).toEqual(['toggle', 'settings', 'quit']);
});
