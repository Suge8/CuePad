export interface CuePadBridge {
	app: {
		version(): Promise<string>;
	};
}
