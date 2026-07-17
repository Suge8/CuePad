import { homedir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { app, BrowserWindow, clipboard, ipcMain, net, protocol, shell, type Tray } from 'electron';
import { CuePadDatabase } from './db';
import { registerSqlIpc } from './ipc-sql';
import {
	isShortcutRegistered,
	registerShortcut,
	unregisterAllShortcuts,
	unregisterShortcut
} from './shortcuts';
import { createDispatchSidecar, type DispatchSidecar } from './sidecar';
import { createTray } from './tray';

const BUNDLE_ID = 'com.sugeh.cuepad';
const DEFAULT_SHORTCUT = 'Alt+Space';
const APP_SCHEME = 'cuepad';
protocol.registerSchemesAsPrivileged([{
	scheme: APP_SCHEME,
	privileges: { standard: true, secure: true, supportFetchAPI: true }
}]);
const isTest = process.env.CUEPAD_TEST === '1';
let database: CuePadDatabase | null = null;
let databasePromise: Promise<CuePadDatabase> | undefined;
let dispatchSidecar: DispatchSidecar | null = null;
let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let quitting = false;
let stoppingSidecar = false;

async function createWindow() {
	const startUrl = process.env.ELECTRON_START_URL;
	if (!startUrl && !app.isPackaged) throw new Error('ELECTRON_START_URL 未设置');

	const window = new BrowserWindow({
		width: 1200,
		height: 760,
		minWidth: 720,
		minHeight: 520,
		show: !isTest,
		titleBarStyle: 'hiddenInset',
		webPreferences: {
			preload: path.join(app.getAppPath(), 'dist-electron', 'preload.js'),
			contextIsolation: true,
			nodeIntegration: false,
			sandbox: true,
			backgroundThrottling: !isTest
		}
	});
	mainWindow = window;
	window.on('close', (event) => {
		if (quitting) return;
		event.preventDefault();
		window.hide();
	});
	window.on('closed', () => {
		if (mainWindow === window) mainWindow = null;
	});
	await window.loadURL(startUrl ?? `${APP_SCHEME}://app/`);
}

function registerAppProtocol() {
	const buildRoot = path.join(app.getAppPath(), 'build');
	protocol.handle(APP_SCHEME, (request) => {
		const pathname = decodeURIComponent(new URL(request.url).pathname);
		const filePath = path.resolve(buildRoot, pathname === '/' ? '200.html' : pathname.slice(1));
		const relativePath = path.relative(buildRoot, filePath);
		if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
			return new Response('Not found', { status: 404 });
		}
		return net.fetch(pathToFileURL(filePath).toString());
	});
}

function showMainWindow() {
	if (isTest || !mainWindow) return;
	mainWindow.show();
	mainWindow.focus();
}

function trayToggleMainWindow() {
	if (!mainWindow) return;
	if (mainWindow.isVisible()) mainWindow.hide();
	else showMainWindow();
}

function hotkeyToggleMainWindow() {
	if (!mainWindow) return;
	if (mainWindow.isVisible() && mainWindow.isFocused()) mainWindow.hide();
	else showMainWindow();
}

function openSettings() {
	showMainWindow();
	mainWindow?.webContents.send('cuepad:open-settings');
}

function databasePath() {
	return path.join(app.getPath('userData'), 'cuepad.db');
}

async function dispatchText(text: string, bundleId: string | null, submit: boolean) {
	const dispatchWindow: { hidden?: BrowserWindow } = {};
	try {
		await dispatchSidecar!.dispatch(bundleId, submit, () => {
			clipboard.writeText(text);
			const window = mainWindow;
			if (!window || window.isDestroyed()) throw new Error('MAIN_WINDOW_UNAVAILABLE');
			window.hide();
			dispatchWindow.hidden = window;
		});
	} catch (error) {
		const window = dispatchWindow.hidden;
		if (window && !window.isDestroyed()) {
			window.show();
			window.focus();
		}
		throw error;
	}
}

function registerDesktopIpc() {
	ipcMain.handle('app:version', () => app.getVersion());
	ipcMain.handle('app:databasePath', databasePath);
	ipcMain.handle('app:revealDataFile', () => shell.showItemInFolder(databasePath()));
	ipcMain.handle('clipboard:writeText', (_event, text: string) => clipboard.writeText(text));
	ipcMain.handle('shortcut:register', (_event, accelerator: string) => {
		registerShortcut(accelerator, hotkeyToggleMainWindow);
	});
	ipcMain.handle('shortcut:unregister', (_event, accelerator: string) => {
		unregisterShortcut(accelerator);
	});
	ipcMain.handle('shortcut:isRegistered', (_event, accelerator: string) => {
		return isShortcutRegistered(accelerator);
	});
	ipcMain.handle('dispatch:target', () => dispatchSidecar!.target());
	ipcMain.handle('dispatch:targets', () => dispatchSidecar!.targets());
	ipcMain.handle('dispatch:text', (_event, text: string, bundleId: string | null, submit: boolean) => {
		return dispatchText(text, bundleId, submit === true);
	});
}

function loadDatabase(): Promise<CuePadDatabase> {
	databasePromise ??= CuePadDatabase.open(
		databasePath(),
		path.join(app.getAppPath(), 'migrations'),
		legacyDatabasePath()
	).then(
		(openedDatabase) => {
			database = openedDatabase;
			return openedDatabase;
		},
		(error) => {
			databasePromise = undefined;
			throw error;
		}
	);
	return databasePromise;
}

function legacyDatabasePath() {
	if (isTest) {
		return process.env.CUEPAD_TEST_LEGACY_DATABASE_PATH
			?? path.join(app.getPath('userData'), 'missing-legacy-cuepad.db');
	}
	return path.join(homedir(), 'Library', 'Application Support', 'com.sugeh.cuepad', 'cuepad.db');
}

function exitWithError(error: unknown) {
	console.error(error);
	app.exit(1);
}

app.whenReady().then(async () => {
	if (app.isPackaged) registerAppProtocol();
	dispatchSidecar = createDispatchSidecar({
		appPath: app.getAppPath(),
		isPackaged: app.isPackaged,
		resourcesPath: process.resourcesPath,
		hostPid: process.pid,
		bundleId: BUNDLE_ID
	});
	void dispatchSidecar.start().catch(console.error);
	registerDesktopIpc();
	registerSqlIpc(loadDatabase);
	try {
		registerShortcut(DEFAULT_SHORTCUT, hotkeyToggleMainWindow);
	} catch (error) {
		console.error(error);
	}
	await createWindow();
	tray = createTray({
		toggle: trayToggleMainWindow,
		openSettings,
		quit: () => app.quit()
	});
	app.on('activate', () => {
		if (mainWindow) showMainWindow();
		else void createWindow().catch(exitWithError);
	});
}).catch(exitWithError);

app.on('before-quit', (event) => {
	quitting = true;
	if (!dispatchSidecar || stoppingSidecar) return;
	event.preventDefault();
	stoppingSidecar = true;
	void dispatchSidecar.close().finally(() => app.quit());
});
app.on('will-quit', () => {
	unregisterAllShortcuts();
	tray?.destroy();
	tray = null;
	database?.close();
	database = null;
	dispatchSidecar = null;
});
