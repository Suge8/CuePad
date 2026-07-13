// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
import type { CuePadBridge } from '../electron/shared/bridge-types';

declare global {
	interface Window {
		cuepad: CuePadBridge;
	}

	namespace App {
		// interface Error {}
		// interface Locals {}
		// interface PageData {}
		// interface PageState {}
		// interface Platform {}
	}
}

export {};
