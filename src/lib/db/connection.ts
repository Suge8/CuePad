import type { SqlDatabase } from './client';

let databasePromise: Promise<SqlDatabase> | undefined;

export function getCuePadDatabase(): Promise<SqlDatabase> {
	databasePromise ??= Promise.resolve(window.cuepad.sql);
	return databasePromise;
}
