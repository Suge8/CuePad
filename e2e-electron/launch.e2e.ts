import { expect, test, _electron, type Page } from '@playwright/test';
import packageJson from '../package.json' with { type: 'json' };

const port = process.env.CUEPAD_ELECTRON_PORT;
if (!port) throw new Error('Electron E2E 端口未设置');
const startUrl = `http://127.0.0.1:${port}`;
const RENDER_TIMEOUT = 20_000;

function observeErrors(page: Page, observedPages: WeakSet<Page>, errors: string[]) {
	if (observedPages.has(page)) return;
	observedPages.add(page);
	page.on('pageerror', (error) => errors.push(error.message));
}

test('安全桥加载 CuePad 且测试窗口保持隐藏', async () => {
	const electronApp = await _electron.launch({
		args: ['.'],
		env: {
			...process.env,
			CUEPAD_TEST: '1',
			ELECTRON_START_URL: startUrl
		}
	});
	let appClosed = false;
	electronApp.on('close', () => {
		appClosed = true;
	});
	const rendererErrors: string[] = [];
	const observedPages = new WeakSet<Page>();
	electronApp.windows().forEach((page) => observeErrors(page, observedPages, rendererErrors));
	electronApp.on('window', (page) => observeErrors(page, observedPages, rendererErrors));

	try {
		const page = await electronApp.firstWindow();
		observeErrors(page, observedPages, rendererErrors);
		// firstWindow 可能先返回 about:blank；每轮独立 Vite 缓存还会触发冷编译。
		await page.waitForURL((url) => url.origin === startUrl, {
			waitUntil: 'domcontentloaded',
			timeout: RENDER_TIMEOUT
		});
		await expect(page).toHaveTitle('CuePad', { timeout: RENDER_TIMEOUT });
		await expect(page.locator('main.app-shell')).toBeVisible({ timeout: RENDER_TIMEOUT });
		await expect(page.locator('.hero-error')).toBeVisible({ timeout: RENDER_TIMEOUT });

		expect(await page.evaluate(() => window.cuepad.app.version())).toBe(packageJson.version);
		expect(await page.evaluate(() => ({
			eventListener: typeof window.cuepad.events.onOpenSettings,
			ipcRenderer: 'ipcRenderer' in window.cuepad,
			require: typeof (window as Window & { require?: unknown }).require,
			process: typeof (window as Window & { process?: unknown }).process
		}))).toEqual({
			eventListener: 'function',
			ipcRenderer: false,
			require: 'undefined',
			process: 'undefined'
		});

		const windowState = await electronApp.evaluate(({ BrowserWindow }) => {
			const window = BrowserWindow.getAllWindows()[0];
			return {
				bounds: window.getBounds(),
				minimumSize: window.getMinimumSize(),
				visible: window.isVisible(),
				focused: window.isFocused(),
				backgroundThrottling: window.webContents.getBackgroundThrottling()
			};
		});
		expect(windowState).toMatchObject({
			bounds: { width: 1200, height: 760 },
			minimumSize: [720, 520],
			visible: false,
			focused: false,
			backgroundThrottling: false
		});
		expect(rendererErrors).toEqual([]);

		const closeEvent = new Promise<void>((resolve) => electronApp.once('close', resolve));
		await page.close();
		await closeEvent;
	} finally {
		if (!appClosed) await electronApp.close();
	}
});
