import { ipcMain } from 'electron';
import type { SqlStatement, SqlValue } from '../src/lib/db/client';
import type { CuePadDatabase } from './db';

export function registerSqlIpc(loadDatabase: () => Promise<CuePadDatabase>) {
	ipcMain.handle('sql:execute', async (_event, query: string, bindValues?: SqlValue[]) => {
		return (await loadDatabase()).execute(query, bindValues);
	});
	ipcMain.handle('sql:select', async (_event, query: string, bindValues?: SqlValue[]) => {
		return (await loadDatabase()).select(query, bindValues);
	});
	ipcMain.handle('sql:executeBatch', async (_event, statements: SqlStatement[]) => {
		return (await loadDatabase()).executeBatch(statements);
	});
}
