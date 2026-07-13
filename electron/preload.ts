import { contextBridge, ipcRenderer } from 'electron';
import type { CuePadBridge } from './shared/bridge-types';

const bridge: CuePadBridge = {
	app: {
		version: () => ipcRenderer.invoke('app:version')
	}
};

contextBridge.exposeInMainWorld('cuepad', bridge);
