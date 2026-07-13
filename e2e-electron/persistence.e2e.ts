import { access, mkdir, readFile, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { expect, test, _electron, type ElectronApplication, type Page } from '@playwright/test';

const port = process.env.CUEPAD_ELECTRON_PORT;
if (!port) throw new Error('Electron E2E 端口未设置');
const startUrl = `http://127.0.0.1:${port}`;
const RENDER_TIMEOUT = 20_000;

async function launchCuePad(userDataPath: string, environment: NodeJS.ProcessEnv = {}) {
	const electronApp = await _electron.launch({
		args: ['.', `--user-data-dir=${userDataPath}`],
		env: {
			...process.env,
			...environment,
			CUEPAD_TEST: '1',
			ELECTRON_START_URL: startUrl
		}
	});
	const page = await electronApp.firstWindow();
	await page.waitForURL((url) => url.origin === startUrl, {
		waitUntil: 'domcontentloaded',
		timeout: RENDER_TIMEOUT
	});
	await expect(page).toHaveTitle('CuePad', { timeout: RENDER_TIMEOUT });
	await expect(page.locator('main.app-shell')).toBeVisible({ timeout: RENDER_TIMEOUT });
	return { electronApp, page };
}

async function createProject(page: Page, name: string) {
	await page.getByRole('button', { name: '新项目' }).click();
	const dialog = page.getByRole('dialog', { name: '新建项目' });
	await dialog.getByPlaceholder('项目名称').fill(name);
	await dialog.getByRole('button', { name: '创建项目' }).click();
	await expect(dialog).toBeHidden();
	await expect(page.getByRole('heading', { name, exact: true })).toBeVisible();
}

async function createCard(page: Page, title: string, body: string, favorite = false) {
	await page.getByRole('button', { name: '新建卡片' }).click();
	await expect(page.locator('.focus')).toBeVisible();
	await page.getByRole('button', { name: '编辑标题' }).click();
	await page.getByRole('textbox', { name: '标题' }).fill(title);
	await page.locator('.cm-content').fill(body);
	if (favorite) await page.locator('.focus').getByRole('button', { name: '收藏' }).click();
	await page.getByRole('button', { name: '退出沉浸编辑（Esc）' }).click();
	await expect(page.locator('.focus')).toBeHidden();
	await expect(page.getByText(title, { exact: true })).toBeVisible();
}

async function createTask(page: Page, content: string) {
	await page.getByRole('button', { name: '新建任务' }).click();
	await page.getByRole('textbox', { name: '任务内容' }).fill(content);
	await page.getByRole('button', { name: '添加任务' }).click();
	await expect(page.locator('[data-task-state="active"]', { hasText: content })).toBeVisible();
}

async function closeApp(electronApp: ElectronApplication) {
	const closed = new Promise<void>((resolve) => electronApp.once('close', resolve));
	await electronApp.close();
	await closed;
}

async function createLegacyDatabase(databasePath: string) {
	await mkdir(path.dirname(databasePath), { recursive: true });
	const database = new DatabaseSync(databasePath);
	database.exec('PRAGMA journal_mode = WAL');
	database.exec('PRAGMA wal_autocheckpoint = 0');
	for (const filename of (await readdir('migrations')).sort()) {
		database.exec(await readFile(path.join('migrations', filename), 'utf8'));
	}
	database.exec(`CREATE TABLE _sqlx_migrations (
		version BIGINT PRIMARY KEY,
		description TEXT NOT NULL,
		installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
		success BOOLEAN NOT NULL,
		checksum BLOB NOT NULL,
		execution_time BIGINT NOT NULL
	)`);
	const recordMigration = database.prepare(
		`INSERT INTO _sqlx_migrations
		 (version, description, success, checksum, execution_time)
		 VALUES (?, ?, TRUE, X'00', 0)`
	);
	for (let version = 1; version <= 5; version += 1) {
		recordMigration.run(version, `legacy-${version}`);
	}
	const timestamp = 1_783_959_600_000;
	database.prepare(
		`INSERT INTO projects
		 (name, color, sort_order, is_pinned, created_at, updated_at)
		 VALUES (?, ?, 0, 1, ?, ?)`
	).run('Legacy Alpha', '#4f8ce8', timestamp, timestamp);
	database.prepare(
		`INSERT INTO cards
		 (project_id, title, body, sort_order, is_favorite, numbering, created_at, updated_at)
		 VALUES (1, ?, ?, 0, 1, 'decimal', ?, ?)`
	).run('Legacy Card', '旧版积累的正文', timestamp, timestamp);
	database.prepare(
		`INSERT INTO tasks
		 (content, project_id, sort_order, completed_at, created_at, updated_at)
		 VALUES (?, 1, 0, NULL, ?, ?)`
	).run('Legacy Task', timestamp, timestamp);
	return database;
}

async function fileExists(filePath: string) {
	return access(filePath).then(() => true, () => false);
}

test('项目、卡片、任务与排序在同一 userData 重启后恢复', async () => {
	const userDataPath = `/tmp/cuepad-electron-e2e/${port}/persistence-user-data`;
	await rm(userDataPath, { recursive: true, force: true });
	let firstApp: ElectronApplication | undefined;
	let secondApp: ElectronApplication | undefined;
	try {
		const firstLaunch = await launchCuePad(userDataPath);
		firstApp = firstLaunch.electronApp;
		const page = firstLaunch.page;
		await page.getByRole('dialog', { name: '欢迎' }).getByRole('button', { name: '开始使用' }).click();
		await page.getByRole('button', { name: '记录灵感' }).click();
		await page.getByRole('button', { name: '退出沉浸编辑（Esc）' }).click();
		await expect(page.locator('.board')).toBeVisible();

		await createProject(page, 'Electron Alpha');
		await createCard(page, 'Alpha One', '第一张卡片正文');
		await createCard(page, 'Alpha Starred', '置顶展示的卡片正文', true);
		await page.evaluate(async () => {
			await window.cuepad.sql.execute(
				`INSERT INTO tags (name, created_at, updated_at) VALUES ($1, $2, $2)`,
				['electron-tag', Date.now()]
			);
			await window.cuepad.sql.execute(
				`INSERT INTO card_tags (card_id, tag_id, created_at)
				 SELECT cards.id, tags.id, $1 FROM cards, tags
				 WHERE cards.title = 'Alpha Starred' AND tags.name = 'electron-tag'`,
				[Date.now()]
			);
		});

		await createProject(page, 'Electron Beta');
		await page.getByRole('button', { name: /^更多项目操作：Electron Beta/ }).click();
		await page.getByRole('button', { name: '置顶项目' }).click();
		await page.locator('[data-project-id]', { hasText: 'Electron Alpha' }).getByRole('button', {
			name: 'Electron Alpha',
			exact: true
		}).click();

		await createTask(page, 'Electron Task One');
		await createTask(page, 'Electron Task Two');
		await page.getByRole('button', { name: '设置' }).click();
		await page.getByRole('dialog', { name: '设置' }).getByRole('button', { name: '深色' }).click();

		const persisted = await page.evaluate(async () => ({
			projects: await window.cuepad.sql.select<{ name: string; is_pinned: number; sort_order: number }[]>(
				`SELECT name, is_pinned, sort_order FROM projects
				 WHERE name LIKE 'Electron %' ORDER BY sort_order`
			),
			cards: await window.cuepad.sql.select<{ title: string; body: string; is_favorite: number; sort_order: number }[]>(
				`SELECT title, body, is_favorite, sort_order FROM cards
				 WHERE title LIKE 'Alpha %' ORDER BY sort_order`
			),
			tasks: await window.cuepad.sql.select<{ content: string; sort_order: number }[]>(
				`SELECT content, sort_order FROM tasks
				 WHERE content LIKE 'Electron Task %' ORDER BY sort_order`
			),
			tags: await window.cuepad.sql.select<{ name: string }[]>(
				`SELECT tags.name FROM tags
				 JOIN card_tags ON card_tags.tag_id = tags.id
				 JOIN cards ON cards.id = card_tags.card_id
				 WHERE cards.title = 'Alpha Starred'`
			),
			settings: await window.cuepad.sql.select<{ value: string }[]>(
				`SELECT value FROM app_settings WHERE key = 'theme'`
			)
		}));
		expect(persisted.projects).toEqual([
			{ name: 'Electron Alpha', is_pinned: 0, sort_order: 0 },
			{ name: 'Electron Beta', is_pinned: 1, sort_order: 1 }
		]);
		expect(persisted.cards).toEqual([
			{ title: 'Alpha Starred', body: '置顶展示的卡片正文', is_favorite: 1, sort_order: -1 },
			{ title: 'Alpha One', body: '第一张卡片正文', is_favorite: 0, sort_order: 0 }
		]);
		expect(persisted.tasks.map((task) => task.content)).toEqual([
			'Electron Task Two',
			'Electron Task One'
		]);
		expect(persisted.tags).toEqual([{ name: 'electron-tag' }]);
		expect(persisted.settings).toEqual([{ value: '"dark"' }]);

		const batchResult = await page.evaluate(async () => {
			await window.cuepad.sql.execute('CREATE TEMP TABLE batch_probe (id INTEGER PRIMARY KEY)');
			let failure = '';
			try {
				await window.cuepad.sql.executeBatch([
					{ query: 'INSERT INTO batch_probe (id) VALUES ($1)', bindValues: [1] },
					{ query: 'INSERT INTO batch_probe (id) VALUES ($1)', bindValues: [1] }
				]);
			} catch (error) {
				failure = String(error);
			}
			const rows = await window.cuepad.sql.select<{ id: number }[]>('SELECT id FROM batch_probe');
			return { failure, rows };
		});
		expect(batchResult.failure).toContain('UNIQUE constraint failed');
		expect(batchResult.rows).toEqual([]);

		await closeApp(firstApp);
		firstApp = undefined;
		const secondLaunch = await launchCuePad(userDataPath);
		secondApp = secondLaunch.electronApp;
		const restartedPage = secondLaunch.page;
		await expect(restartedPage.getByRole('heading', { name: 'Electron Alpha', exact: true })).toBeVisible();
		expect(await restartedPage.locator('[data-project-id]').evaluateAll((items) =>
			items.map((item) => item.textContent?.trim()).filter((text) => text?.startsWith('Electron'))
		)).toEqual(['Electron Beta', 'Electron Alpha']);
		expect(await restartedPage.locator('[data-card-id]').evaluateAll((items) =>
			items.map((item) => item.querySelector('h3')?.textContent?.trim()).filter(Boolean)
		)).toEqual(['Alpha Starred', 'Alpha One']);
		expect(await restartedPage.locator('[data-task-state="active"]').evaluateAll((items) =>
			items.map((item) => item.textContent).filter((text) => text?.includes('Electron Task'))
		)).toEqual(expect.arrayContaining([
			expect.stringContaining('Electron Task Two'),
			expect.stringContaining('Electron Task One')
		]));
		const taskOrder = await restartedPage.locator('[data-task-state="active"]').evaluateAll((items) =>
			items.map((item) => item.textContent?.match(/Electron Task (One|Two)/)?.[0]).filter(Boolean)
		);
		expect(taskOrder).toEqual(['Electron Task Two', 'Electron Task One']);
		expect(await restartedPage.evaluate(() => document.documentElement.dataset.theme)).toBe('dark');
		await restartedPage.getByText('Alpha Starred', { exact: true }).click();
		await expect(restartedPage.getByRole('button', { name: 'electron-tag，选颜色' })).toBeVisible();
	} finally {
		if (firstApp) await firstApp.close();
		if (secondApp) await secondApp.close();
	}
});


test('首次启动复制 Tauri v5 数据并兼容 sqlx 迁移账本', async () => {
	const fixtureRoot = `/tmp/cuepad-electron-e2e/${port}/legacy-fixture`;
	const userDataPath = `/tmp/cuepad-electron-e2e/${port}/legacy-user-data`;
	const legacyDatabasePath = path.join(
		fixtureRoot,
		'Library',
		'Application Support',
		'com.sugeh.cuepad',
		'cuepad.db'
	);
	await Promise.all([
		rm(fixtureRoot, { recursive: true, force: true }),
		rm(userDataPath, { recursive: true, force: true })
	]);
	const legacyDatabase = await createLegacyDatabase(legacyDatabasePath);
	const suffixes = ['', '-wal', '-shm'];
	const originalFiles = new Map<string, Buffer>();
	for (const suffix of suffixes) {
		expect(await fileExists(`${legacyDatabasePath}${suffix}`)).toBe(true);
		originalFiles.set(suffix, await readFile(`${legacyDatabasePath}${suffix}`));
	}

	let electronApp: ElectronApplication | undefined;
	try {
		const launch = await launchCuePad(userDataPath, {
			CUEPAD_TEST_LEGACY_DATABASE_PATH: legacyDatabasePath
		});
		electronApp = launch.electronApp;
		const page = launch.page;
		await expect(page.getByRole('heading', { name: 'Legacy Alpha', exact: true })).toBeVisible({
			timeout: RENDER_TIMEOUT
		});
		await expect(page.getByText('Legacy Card', { exact: true })).toBeVisible();
		await expect(page.locator('[data-task-state="active"]', { hasText: 'Legacy Task' })).toBeVisible();
		await expect(page.locator('.hero-error')).toHaveCount(0);

		const inherited = await page.evaluate(async () => ({
			migrations: await window.cuepad.sql.select<{ version: number }[]>(
				'SELECT version FROM schema_migrations ORDER BY version'
			),
			projects: await window.cuepad.sql.select<{ name: string; is_pinned: number }[]>(
				'SELECT name, is_pinned FROM projects'
			),
			cards: await window.cuepad.sql.select<{ title: string; body: string; is_favorite: number }[]>(
				'SELECT title, body, is_favorite FROM cards'
			),
			tasks: await window.cuepad.sql.select<{ content: string; project_id: number }[]>(
				'SELECT content, project_id FROM tasks'
			),
			sqlxRows: await window.cuepad.sql.select<{ count: number }[]>(
				'SELECT COUNT(*) AS count FROM _sqlx_migrations WHERE success = 1'
			)
		}));
		expect(inherited).toEqual({
			migrations: [{ version: 1 }, { version: 2 }, { version: 3 }, { version: 4 }, { version: 5 }],
			projects: [{ name: 'Legacy Alpha', is_pinned: 1 }],
			cards: [{ title: 'Legacy Card', body: '旧版积累的正文', is_favorite: 1 }],
			tasks: [{ content: 'Legacy Task', project_id: 1 }],
			sqlxRows: [{ count: 5 }]
		});
		expect(await fileExists(path.join(userDataPath, 'cuepad.db'))).toBe(true);
		await page.evaluate(() => window.cuepad.sql.execute(
			'UPDATE projects SET name = $1 WHERE id = $2',
			['Inherited Copy', 1]
		));
		await closeApp(electronApp);
		electronApp = undefined;
		const restart = await launchCuePad(userDataPath, {
			CUEPAD_TEST_LEGACY_DATABASE_PATH: legacyDatabasePath
		});
		electronApp = restart.electronApp;
		await expect(restart.page.getByRole('heading', { name: 'Inherited Copy', exact: true })).toBeVisible();
		for (const suffix of suffixes) {
			expect(await readFile(`${legacyDatabasePath}${suffix}`)).toEqual(originalFiles.get(suffix));
		}
	} finally {
		if (electronApp) await electronApp.close();
		legacyDatabase.close();
	}
});

test('旧库复制失败进入加载错误态且不创建空库', async () => {
	const fixtureRoot = `/tmp/cuepad-electron-e2e/${port}/invalid-legacy`;
	const userDataPath = `/tmp/cuepad-electron-e2e/${port}/copy-failure-user-data`;
	await Promise.all([
		rm(fixtureRoot, { recursive: true, force: true }),
		rm(userDataPath, { recursive: true, force: true })
	]);
	await mkdir(fixtureRoot, { recursive: true });
	let electronApp: ElectronApplication | undefined;
	try {
		const launch = await launchCuePad(userDataPath, {
			CUEPAD_TEST_LEGACY_DATABASE_PATH: fixtureRoot
		});
		electronApp = launch.electronApp;
		await expect(launch.page.locator('.hero-error')).toContainText('继承旧数据库失败', {
			timeout: RENDER_TIMEOUT
		});
		expect(await fileExists(path.join(userDataPath, 'cuepad.db'))).toBe(false);
	} finally {
		if (electronApp) await electronApp.close();
	}
});
