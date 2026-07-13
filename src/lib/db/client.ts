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
