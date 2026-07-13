import { contextBridge, ipcRenderer } from 'electron';
import type { CuePadBridge } from './shared/bridge-types';

const bridge: CuePadBridge = {
	app: {
		version: () => ipcRenderer.invoke('app:version')
	},
	events: {
		onOpenSettings(listener) {
			const wrapped = () => listener();
			ipcRenderer.on('cuepad:open-settings', wrapped);
			return () => ipcRenderer.removeListener('cuepad:open-settings', wrapped);
		}
	}
};

contextBridge.exposeInMainWorld('cuepad', bridge);
