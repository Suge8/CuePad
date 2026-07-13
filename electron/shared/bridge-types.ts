export interface CuePadBridge {
	app: {
		version(): Promise<string>;
	};
	events: {
		onOpenSettings(listener: () => void): () => void;
	};
}

declare global {
	interface Window {
		cuepad: CuePadBridge;
	}
}
