export const CUEPAD_DATABASE_URL = 'sqlite:cuepad.db';

export type SqlValue = string | number | null;

export interface SqlExecuteResult {
	rowsAffected: number;
	lastInsertId?: number;
}

export interface SqlStatement {
	query: string;
	bindValues?: SqlValue[];
}

export interface SqlDatabase {
	execute(query: string, bindValues?: SqlValue[]): Promise<SqlExecuteResult>;
	select<T>(query: string, bindValues?: SqlValue[]): Promise<T>;
	executeBatch(statements: SqlStatement[]): Promise<void>;
}

/**
 * 把多条带参语句合并为单次 BEGIN IMMEDIATE...COMMIT 执行。
 * sqlx 的 SQLite driver 对多语句 prepared query 按参数偏移顺序执行，
 * 单次 execute 落在同一池连接上，提交路径原子（已运行时验证）。
 */
export function mergeStatements(statements: SqlStatement[]): SqlStatement {
	let parameterOffset = 0;
	const bindValues: SqlValue[] = [];
	const queries = statements.map((statement) => {
		const values = statement.bindValues ?? [];
		const query = statement.query.replace(/\$(\d+)/g, (_, index: string) => {
			return `$${Number(index) + parameterOffset}`;
		});

		parameterOffset += values.length;
		bindValues.push(...values);
		return query.replace(/;\s*$/, '');
	});

	return {
		query: `BEGIN IMMEDIATE;\n${queries.join(';\n')};\nCOMMIT;`,
		bindValues
	};
}
