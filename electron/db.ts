import { access, copyFile, mkdir, readdir, readFile, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { DatabaseSync, type StatementSync } from 'node:sqlite';
import type { SqlExecuteResult, SqlStatement, SqlValue } from '../src/lib/db/client';

const DATABASE_SIDECARS = ['-wal', '-shm'] as const;
const MIGRATION_FILENAME = /^(\d+)_.*\.sql$/;

type Migration = {
	version: number;
	sql: string;
};

type SqliteResult = {
	changes: number | bigint;
	lastInsertRowid: number | bigint;
};

export class CuePadDatabase {
	private constructor(private readonly database: DatabaseSync) {}

	static async open(databasePath: string, migrationsPath: string, legacyDatabasePath: string) {
		const migrations = await loadMigrations(migrationsPath);
		await mkdir(path.dirname(databasePath), { recursive: true });
		await inheritLegacyDatabase(databasePath, legacyDatabasePath);

		const database = new DatabaseSync(databasePath);
		try {
			database.exec('PRAGMA journal_mode = WAL');
			database.exec('PRAGMA foreign_keys = ON');
			database.exec('PRAGMA busy_timeout = 5000');
			applyMigrations(database, migrations);
			return new CuePadDatabase(database);
		} catch (error) {
			database.close();
			throw error;
		}
	}

	execute(query: string, bindValues: SqlValue[] = []): SqlExecuteResult {
		const result = run(this.database.prepare(query), bindValues);
		return {
			rowsAffected: Number(result.changes),
			lastInsertId: Number(result.lastInsertRowid)
		};
	}

	select<T>(query: string, bindValues: SqlValue[] = []): T {
		const statement = this.database.prepare(query);
		return (bindValues.length > 0
			? statement.all(namedParameters(bindValues))
			: statement.all()) as T;
	}

	executeBatch(statements: SqlStatement[]): void {
		if (statements.length === 0) return;
		this.database.exec('BEGIN IMMEDIATE');
		try {
			for (const statement of statements) {
				run(this.database.prepare(statement.query), statement.bindValues ?? []);
			}
			this.database.exec('COMMIT');
		} catch (error) {
			try {
				this.database.exec('ROLLBACK');
			} catch (rollbackError) {
				console.error('SQLite batch rollback failed', rollbackError);
			}
			throw error;
		}
	}

	close() {
		this.database.close();
	}
}

async function loadMigrations(migrationsPath: string): Promise<Migration[]> {
	const filenames = (await readdir(migrationsPath)).filter((filename) => MIGRATION_FILENAME.test(filename));
	const migrations = await Promise.all(
		filenames.map(async (filename) => ({
			version: Number(filename.match(MIGRATION_FILENAME)?.[1]),
			sql: await readFile(path.join(migrationsPath, filename), 'utf8')
		}))
	);
	migrations.sort((left, right) => left.version - right.version);
	if (migrations.length === 0) throw new Error(`未找到 SQLite migrations：${migrationsPath}`);
	for (let index = 1; index < migrations.length; index += 1) {
		if (migrations[index - 1].version === migrations[index].version) {
			throw new Error(`SQLite migration version 重复：${migrations[index].version}`);
		}
	}
	return migrations;
}

async function inheritLegacyDatabase(databasePath: string, legacyDatabasePath: string) {
	if (await exists(databasePath) || !(await exists(legacyDatabasePath))) return;

	const presentSuffixes: string[] = [''];
	for (const suffix of DATABASE_SIDECARS) {
		if (await exists(`${legacyDatabasePath}${suffix}`)) presentSuffixes.push(suffix);
	}

	const transferId = randomUUID();
	const temporaryPath = (suffix: string) => `${databasePath}${suffix}.inherit-${transferId}`;
	const installedPaths: string[] = [];
	try {
		for (const suffix of presentSuffixes) {
			await copyFile(`${legacyDatabasePath}${suffix}`, temporaryPath(suffix));
		}
		for (const suffix of DATABASE_SIDECARS) {
			await rm(`${databasePath}${suffix}`, { force: true });
			if (!presentSuffixes.includes(suffix)) continue;
			await rename(temporaryPath(suffix), `${databasePath}${suffix}`);
			installedPaths.push(`${databasePath}${suffix}`);
		}
		await rename(temporaryPath(''), databasePath);
		installedPaths.push(databasePath);
	} catch (cause) {
		await Promise.all([
			...presentSuffixes.map((suffix) => rm(temporaryPath(suffix), { force: true })),
			...installedPaths.map((installedPath) => rm(installedPath, { force: true }))
		]);
		throw new Error(`继承旧数据库失败：${legacyDatabasePath}`, { cause });
	}
}

async function exists(filePath: string): Promise<boolean> {
	try {
		await access(filePath);
		return true;
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
		throw error;
	}
}

function applyMigrations(database: DatabaseSync, migrations: Migration[]) {
	database.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version INTEGER PRIMARY KEY,
		applied_at INTEGER NOT NULL
	)`);
	seedSqlxMigrations(database, migrations);
	const applied = new Set(
		(database.prepare('SELECT version FROM schema_migrations').all() as { version: number }[])
			.map((row) => row.version)
	);
	const record = database.prepare(
		'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)'
	);
	for (const migration of migrations) {
		if (applied.has(migration.version)) continue;
		database.exec('BEGIN IMMEDIATE');
		try {
			database.exec(migration.sql);
			record.run(migration.version, Date.now());
			database.exec('COMMIT');
		} catch (error) {
			database.exec('ROLLBACK');
			throw error;
		}
	}
}

function seedSqlxMigrations(database: DatabaseSync, migrations: Migration[]) {
	const sqlxTable = database.prepare(
		"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'"
	).get();
	if (!sqlxTable) return;
	const row = database.prepare(
		'SELECT MAX(version) AS version FROM _sqlx_migrations WHERE success = 1'
	).get() as { version: number | null };
	if (row.version === null) return;

	const record = database.prepare(
		'INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (?, ?)'
	);
	const appliedAt = Date.now();
	for (const migration of migrations) {
		if (migration.version <= row.version) record.run(migration.version, appliedAt);
	}
}

function namedParameters(bindValues: SqlValue[]): Record<string, SqlValue> {
	return Object.fromEntries(bindValues.map((value, index) => [`$${index + 1}`, value]));
}

function run(statement: StatementSync, bindValues: SqlValue[]): SqliteResult {
	return (bindValues.length > 0
		? statement.run(namedParameters(bindValues))
		: statement.run()) as SqliteResult;
}
