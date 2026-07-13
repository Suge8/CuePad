import type { SqlDatabase, SqlExecuteResult, SqlValue } from './client';

export interface RepositoryContext {
	loadDatabase: () => Promise<SqlDatabase>;
}

export async function selectOne<Row>(database: SqlDatabase, query: string, values: SqlValue[]): Promise<Row | null> {
	const rows = await database.select<Row[]>(query, values);
	return rows[0] ?? null;
}

export function assign(assignments: string[], values: SqlValue[], column: string, value: SqlValue) {
	values.push(value);
	assignments.push(`${column} = $${values.length}`);
}

export function assignOptional(
	assignments: string[],
	values: SqlValue[],
	column: string,
	value: SqlValue | undefined
) {
	if (value !== undefined) assign(assignments, values, column, value);
}

export function optionalBoolean(value: boolean | undefined): number | undefined {
	return value === undefined ? undefined : toSqlBoolean(value);
}

export function toSqlBoolean(value: boolean): number {
	return value ? 1 : 0;
}

export function insertedId(result: SqlExecuteResult): number {
	if (typeof result.lastInsertId !== 'number') throw new Error('SQLite did not return lastInsertId.');
	return result.lastInsertId;
}

export function where(conditions: string[]): string {
	return conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
}

export function nowMs(): number {
	return Date.now();
}

export function createDeleteBatchId(): string {
	return globalThis.crypto.randomUUID();
}
