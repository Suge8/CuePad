import { contextBridge, ipcRenderer } from 'electron';
import type { CuePadBridge } from './shared/bridge-types';

const bridge: CuePadBridge = {
	app: {
		version: () => ipcRenderer.invoke('app:version'),
		databasePath: () => ipcRenderer.invoke('app:databasePath'),
		revealDataFile: () => ipcRenderer.invoke('app:revealDataFile')
	},
	clipboard: {
		writeText: (text) => ipcRenderer.invoke('clipboard:writeText', text)
	},
	dispatch: {
		target: () => ipcRenderer.invoke('dispatch:target'),
		targets: () => ipcRenderer.invoke('dispatch:targets'),
		text: (text, bundleId, submit) => ipcRenderer.invoke('dispatch:text', text, bundleId, submit)
	},
	events: {
		onOpenSettings(listener) {
			const wrapped = () => listener();
			ipcRenderer.on('cuepad:open-settings', wrapped);
			return () => ipcRenderer.removeListener('cuepad:open-settings', wrapped);
		}
	},
	shortcut: {
		register: (accelerator) => ipcRenderer.invoke('shortcut:register', accelerator),
		unregister: (accelerator) => ipcRenderer.invoke('shortcut:unregister', accelerator),
		isRegistered: (accelerator) => ipcRenderer.invoke('shortcut:isRegistered', accelerator)
	},
	sql: {
		execute: (query, bindValues) => ipcRenderer.invoke('sql:execute', query, bindValues),
		select: (query, bindValues) => ipcRenderer.invoke('sql:select', query, bindValues),
		executeBatch: (statements) => ipcRenderer.invoke('sql:executeBatch', statements)
	}
};

contextBridge.exposeInMainWorld('cuepad', bridge);
