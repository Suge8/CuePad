import { homedir } from 'node:os';
import path from 'node:path';
import { app, BrowserWindow, ipcMain } from 'electron';
import { CuePadDatabase } from './db';
import { registerSqlIpc } from './ipc-sql';

const isTest = process.env.CUEPAD_TEST === '1';
let database: CuePadDatabase | null = null;
let databasePromise: Promise<CuePadDatabase> | undefined;
let mainWindow: BrowserWindow | null = null;

async function createWindow() {
	const startUrl = process.env.ELECTRON_START_URL;
	if (!startUrl) throw new Error('ELECTRON_START_URL 未设置');

	mainWindow = new BrowserWindow({
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
	mainWindow.on('closed', () => {
		mainWindow = null;
	});
	await mainWindow.loadURL(startUrl);
}

function loadDatabase(): Promise<CuePadDatabase> {
	databasePromise ??= CuePadDatabase.open(
		path.join(app.getPath('userData'), 'cuepad.db'),
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
			?? path.join(app.getPath('userData'), 'missing-tauri-cuepad.db');
	}
	return path.join(homedir(), 'Library', 'Application Support', 'com.sugeh.cuepad', 'cuepad.db');
}

function exitWithError(error: unknown) {
	console.error(error);
	app.exit(1);
}

app.whenReady().then(async () => {
	ipcMain.handle('app:version', () => app.getVersion());
	registerSqlIpc(loadDatabase);
	await createWindow();
	app.on('activate', () => {
		if (BrowserWindow.getAllWindows().length === 0) void createWindow().catch(exitWithError);
	});
}).catch(exitWithError);

app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => {
	database?.close();
	database = null;
});
