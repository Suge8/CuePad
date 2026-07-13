import Database from '@tauri-apps/plugin-sql';
import { CUEPAD_DATABASE_URL, mergeStatements, type SqlDatabase, type SqlValue } from './client';

let databasePromise: Promise<SqlDatabase> | undefined;

export function getCuePadDatabase(): Promise<SqlDatabase> {
	databasePromise ??= loadCuePadDatabase();
	return databasePromise;
}

// sqlx 的 SqliteConnectOptions 默认对每个池连接启用 foreign_keys=ON，无需手动 PRAGMA。
async function loadCuePadDatabase(): Promise<SqlDatabase> {
	const database = await Database.load(CUEPAD_DATABASE_URL);

	return {
		execute(query, bindValues) {
			return database.execute(query, bindValues);
		},
		select<T>(query: string, bindValues?: SqlValue[]) {
			return database.select<T>(query, bindValues);
		},
		async executeBatch(statements) {
			if (statements.length === 0) return;
			const batch = mergeStatements(statements);
			try {
				await database.execute(batch.query, batch.bindValues);
			} catch (cause) {
				// 中途失败会跳过 COMMIT，把未提交事务悬挂在某个池连接上，
				// 后续写入可能落入该孤儿事务而静默丢失（运行时实测）。
				// 关闭连接池强制 SQLite 回滚未提交事务，再重建池
				//（插件 load 对同一 URL 会覆盖为全新 pool，且不会重跑迁移）。
				await database.close().catch(() => undefined);
				await Database.load(CUEPAD_DATABASE_URL);
				throw cause;
			}
		}
	};
}
