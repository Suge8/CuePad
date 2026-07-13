import type { SqlExecuteResult, SqlStatement, SqlValue } from '../../src/lib/db/client';

export interface CuePadBridge {
	app: {
		version(): Promise<string>;
	};
	events: {
		onOpenSettings(listener: () => void): () => void;
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
