import type { SqlExecuteResult, SqlStatement, SqlValue } from '../../src/lib/db/client';

export interface DispatchApp {
	bundleId: string | null;
	name: string;
}

export interface CuePadBridge {
	app: {
		version(): Promise<string>;
		databasePath(): Promise<string>;
		revealDataFile(): Promise<void>;
	};
	clipboard: {
		writeText(text: string): Promise<void>;
	};
	dispatch: {
		target(): Promise<DispatchApp | null>;
		targets(): Promise<DispatchApp[]>;
		text(text: string, bundleId: string | null): Promise<void>;
	};
	events: {
		onOpenSettings(listener: () => void): () => void;
	};
	shortcut: {
		register(accelerator: string): Promise<void>;
		unregister(accelerator: string): Promise<void>;
		isRegistered(accelerator: string): Promise<boolean>;
	};
	sql: {
		execute(query: string, bindValues?: SqlValue[]): Promise<SqlExecuteResult>;
		select<T>(query: string, bindValues?: SqlValue[]): Promise<T>;
		executeBatch(statements: SqlStatement[]): Promise<void>;
	};
}

declare global {
	interface Window {
		cuepad: CuePadBridge;
	}
}
