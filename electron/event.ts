const OPEN_SETTINGS_EVENT = 'cuepad://open-settings';

type UnlistenFn = () => void;
type EventCallback<T> = (event: { event: string; id: number; payload: T }) => void;

export async function listen<T>(event: string, callback: EventCallback<T>): Promise<UnlistenFn> {
	if (event !== OPEN_SETTINGS_EVENT) throw new Error(`Electron 不支持事件：${event}`);
	return window.cuepad.events.onOpenSettings(() => {
		callback({ event, id: 0, payload: null as T });
	});
}
