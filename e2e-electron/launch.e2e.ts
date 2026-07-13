import { rm } from 'node:fs/promises';
import { expect, test, _electron, type ElectronApplication, type Page } from '@playwright/test';
import packageJson from '../package.json' with { type: 'json' };

const port = process.env.CUEPAD_ELECTRON_PORT;
if (!port) throw new Error('Electron E2E 端口未设置');
const startUrl = `http://127.0.0.1:${port}`;
const RENDER_TIMEOUT = 20_000;
const CUSTOM_SHORTCUT = 'Control+Alt+KeyU';
const CUSTOM_ELECTRON_SHORTCUT = 'Control+Alt+U';

function observeErrors(page: Page, observedPages: WeakSet<Page>, errors: string[]) {
	if (observedPages.has(page)) return;
	observedPages.add(page);
	page.on('pageerror', (error) => errors.push(error.message));
}

async function waitForRenderer(electronApp: ElectronApplication, errors: string[]) {
	const observedPages = new WeakSet<Page>();
	electronApp.windows().forEach((page) => observeErrors(page, observedPages, errors));
	electronApp.on('window', (page) => observeErrors(page, observedPages, errors));
	const page = await electronApp.firstWindow();
	observeErrors(page, observedPages, errors);
	await page.waitForURL((url) => url.origin === startUrl, {
		waitUntil: 'domcontentloaded',
		timeout: RENDER_TIMEOUT
	});
	await expect(page).toHaveTitle('CuePad', { timeout: RENDER_TIMEOUT });
	await expect(page.locator('main.app-shell')).toBeVisible({ timeout: RENDER_TIMEOUT });
	return page;
}

async function closeApp(electronApp: ElectronApplication) {
	const closed = new Promise<void>((resolve) => electronApp.once('close', resolve));
	await electronApp.close();
	await closed;
}

test('桌面壳安全桥、快捷键、剪贴板、拖拽区与 close=hide', async () => {
	const userDataPath = `/tmp/cuepad-electron-e2e/${port}/launch-user-data`;
	await rm(userDataPath, { recursive: true, force: true });
	let electronApp: ElectronApplication | undefined;
	let restartedApp: ElectronApplication | undefined;
	let appClosed = false;
	const rendererErrors: string[] = [];

	try {
		electronApp = await _electron.launch({
			args: ['.', `--user-data-dir=${userDataPath}`],
			env: { ...process.env, CUEPAD_TEST: '1', ELECTRON_START_URL: startUrl }
		});
		electronApp.on('close', () => {
			appClosed = true;
		});
		const page = await waitForRenderer(electronApp, rendererErrors);
		await expect(page.locator('.hero-start')).toBeVisible({ timeout: RENDER_TIMEOUT });
		await expect(page.locator('.hero-error')).toHaveCount(0);

		const expectedDatabasePath = await electronApp.evaluate(({ app }) =>
			`${app.getPath('userData')}/cuepad.db`
		);
		expect(await page.evaluate(() => window.cuepad.app.version())).toBe(packageJson.version);
		expect(await page.evaluate(() => window.cuepad.app.databasePath())).toBe(expectedDatabasePath);
		expect(await page.evaluate(() => ({
			appDatabasePath: typeof window.cuepad.app.databasePath,
			appRevealDataFile: typeof window.cuepad.app.revealDataFile,
			clipboardWriteText: typeof window.cuepad.clipboard.writeText,
			dispatchTarget: typeof window.cuepad.dispatch.target,
			dispatchTargets: typeof window.cuepad.dispatch.targets,
			dispatchText: typeof window.cuepad.dispatch.text,
			eventListener: typeof window.cuepad.events.onOpenSettings,
			shortcutRegister: typeof window.cuepad.shortcut.register,
			shortcutUnregister: typeof window.cuepad.shortcut.unregister,
			shortcutIsRegistered: typeof window.cuepad.shortcut.isRegistered,
			sqlExecute: typeof window.cuepad.sql.execute,
			sqlSelect: typeof window.cuepad.sql.select,
			sqlExecuteBatch: typeof window.cuepad.sql.executeBatch,
			ipcRenderer: 'ipcRenderer' in window.cuepad,
			require: typeof (window as Window & { require?: unknown }).require,
			process: typeof (window as Window & { process?: unknown }).process
		}))).toEqual({
			appDatabasePath: 'function',
			appRevealDataFile: 'function',
			clipboardWriteText: 'function',
			dispatchTarget: 'function',
			dispatchTargets: 'function',
			dispatchText: 'function',
			eventListener: 'function',
			shortcutRegister: 'function',
			shortcutUnregister: 'function',
			shortcutIsRegistered: 'function',
			sqlExecute: 'function',
			sqlSelect: 'function',
			sqlExecuteBatch: 'function',
			ipcRenderer: false,
			require: 'undefined',
			process: 'undefined'
		});
		expect(await page.evaluate(() => window.cuepad.sql.select<{ version: number }[]>(
			'SELECT version FROM schema_migrations ORDER BY version'
		))).toEqual([{ version: 1 }, { version: 2 }, { version: 3 }, { version: 4 }, { version: 5 }]);

		expect(await electronApp.evaluate(({ globalShortcut }) =>
			globalShortcut.isRegistered('Alt+Space')
		)).toBe(true);
		const originalClipboard = await electronApp.evaluate(({ clipboard }) => clipboard.readText());
		try {
			const clipboardProbe = `CuePad Electron ${port}`;
			await page.evaluate((text) => window.cuepad.clipboard.writeText(text), clipboardProbe);
			expect(await electronApp.evaluate(({ clipboard }) => clipboard.readText())).toBe(clipboardProbe);
		} finally {
			await electronApp.evaluate(({ clipboard }, text) => clipboard.writeText(text), originalClipboard);
		}

		const welcome = page.getByRole('dialog', { name: '欢迎' });
		if (await welcome.isVisible()) {
			await welcome.getByRole('button', { name: '开始使用' }).click();
			await expect(welcome).toBeHidden();
		}
		await electronApp.evaluate(({ BrowserWindow }) => {
			BrowserWindow.getAllWindows()[0].webContents.send('cuepad:open-settings');
		});
		const settings = page.getByRole('dialog', { name: '设置' });
		await expect(settings).toBeVisible();
		await expect(settings.getByText(expectedDatabasePath)).toBeVisible();
		await expect(settings.getByText(`CuePad v${packageJson.version}`)).toBeVisible();

		await settings.getByRole('button', { name: '重新录制全局快捷键' }).click();
		await settings.locator('[data-shortcut-recorder]').dispatchEvent('keydown', {
			key: 'u',
			code: 'KeyU',
			ctrlKey: true,
			altKey: true,
			bubbles: true
		});
		await expect.poll(() => electronApp?.evaluate(({ globalShortcut }, customShortcut) => ({
			custom: globalShortcut.isRegistered(customShortcut),
			default: globalShortcut.isRegistered('Alt+Space')
		}), CUSTOM_ELECTRON_SHORTCUT)).toEqual({ custom: true, default: false });
		expect(await page.evaluate(async () => window.cuepad.sql.select<{ value: string }[]>(
			`SELECT value FROM app_settings WHERE key = 'globalShortcut'`
		))).toEqual([{ value: JSON.stringify(CUSTOM_SHORTCUT) }]);
		await settings.getByRole('button', { name: '关闭' }).click();
		await expect(settings).toBeHidden();

		await page.getByRole('button', { name: '记录灵感' }).click();
		await expect(page.locator('.focus')).toBeVisible();
		expect(await page.evaluate(() => {
			const region = (selector: string) => getComputedStyle(
				document.querySelector<HTMLElement>(selector)!
			).getPropertyValue('-webkit-app-region');
			return {
				topbar: region('.topbar'),
				search: region('.searchbar'),
				focusBar: region('.focus-bar'),
				focusButton: region('.focus-bar button'),
				barDrag: region('.bar-drag')
			};
		})).toEqual({
			topbar: 'drag',
			search: 'no-drag',
			focusBar: 'drag',
			focusButton: 'no-drag',
			barDrag: 'drag'
		});

		const windowState = await electronApp.evaluate(({ BrowserWindow }) => {
			const window = BrowserWindow.getAllWindows()[0];
			window.close();
			return {
				bounds: window.getBounds(),
				minimumSize: window.getMinimumSize(),
				visible: window.isVisible(),
				focused: window.isFocused(),
				windowCount: BrowserWindow.getAllWindows().length,
				backgroundThrottling: window.webContents.getBackgroundThrottling()
			};
		});
		expect(windowState).toMatchObject({
			bounds: { width: 1200, height: 760 },
			minimumSize: [720, 520],
			visible: false,
			focused: false,
			windowCount: 1,
			backgroundThrottling: false
		});
		expect(appClosed).toBe(false);
		expect(rendererErrors).toEqual([]);

		await closeApp(electronApp);
		electronApp = undefined;
		restartedApp = await _electron.launch({
			args: ['.', `--user-data-dir=${userDataPath}`],
			env: { ...process.env, CUEPAD_TEST: '1', ELECTRON_START_URL: startUrl }
		});
		await waitForRenderer(restartedApp, rendererErrors);
		await expect.poll(() => restartedApp?.evaluate(({ globalShortcut }, customShortcut) => ({
			custom: globalShortcut.isRegistered(customShortcut),
			default: globalShortcut.isRegistered('Alt+Space')
		}), CUSTOM_ELECTRON_SHORTCUT)).toEqual({ custom: true, default: false });
		expect(rendererErrors).toEqual([]);
	} finally {
		if (electronApp) await electronApp.close();
		if (restartedApp) await restartedApp.close();
	}
});
