import path from 'node:path';
import { app, Menu, nativeImage, Tray } from 'electron';

export function createTray(actions: {
	toggle(): void;
	openSettings(): void;
	quit(): void;
}): Tray {
	const image = nativeImage.createFromPath(
		path.join(app.getAppPath(), 'electron', 'assets', 'trayTemplate.png')
	);
	if (image.isEmpty()) throw new Error('无法加载托盘图标');
	image.setTemplateImage(true);

	const tray = new Tray(image);
	tray.setToolTip('CuePad');
	tray.setContextMenu(Menu.buildFromTemplate([
		{ label: '显示 / 隐藏', click: actions.toggle },
		{ label: '设置', click: actions.openSettings },
		{ label: '退出 CuePad', click: actions.quit }
	]));
	return tray;
}
