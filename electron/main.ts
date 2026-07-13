import path from 'node:path';
import { app, BrowserWindow, ipcMain } from 'electron';

const isTest = process.env.CUEPAD_TEST === '1';
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

function exitWithError(error: unknown) {
	console.error(error);
	app.exit(1);
}

app.whenReady().then(async () => {
	ipcMain.handle('app:version', () => app.getVersion());
	await createWindow();
	app.on('activate', () => {
		if (BrowserWindow.getAllWindows().length === 0) void createWindow().catch(exitWithError);
	});
}).catch(exitWithError);

app.on('window-all-closed', () => app.quit());
