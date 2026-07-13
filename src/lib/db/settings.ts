import { mapSetting, type AppSettingRow } from './rows';
import { nowMs, selectOne, type RepositoryContext } from './repository-context';
import { encodeSettingValue } from './settings-codec';
import type { AppSetting, AppSettings, SettingValue } from './types';

export async function getAppSetting(context: RepositoryContext, key: string): Promise<AppSetting | null> {
	const database = await context.loadDatabase();
	const row = await selectOne<AppSettingRow>(database, `SELECT * FROM app_settings WHERE key = $1`, [key]);
	return row ? mapSetting(row) : null;
}

export async function getSettings(context: RepositoryContext): Promise<AppSettings> {
	const database = await context.loadDatabase();
	const rows = await database.select<AppSettingRow[]>(`SELECT * FROM app_settings ORDER BY key`, []);
	const settings: AppSettings = {};
	for (const row of rows) settings[row.key] = mapSetting(row).value;
	return settings;
}

export async function setSetting(context: RepositoryContext, key: string, value: SettingValue): Promise<void> {
	const database = await context.loadDatabase();
	const timestamp = nowMs();
	await database.execute(
		`INSERT INTO app_settings (key, value, created_at, updated_at)
		 VALUES ($1, $2, $3, $3)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		[key, encodeSettingValue(value), timestamp]
	);
}
