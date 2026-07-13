import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Database } from 'bun:sqlite';
import { describe, expect, test } from 'bun:test';
import { createCuePadRepository } from '../src/lib/db/repository';
import { INBOX_PROJECT } from '../src/lib/db/types';
import type { SqlDatabase, SqlExecuteResult, SqlStatement, SqlValue } from '../src/lib/db/client';

class BunSqliteDatabase implements SqlDatabase {
	constructor(private readonly database: Database) {}

	async execute(query: string, bindValues: SqlValue[] = []): Promise<SqlExecuteResult> {
		const result = this.database.query(query).run(...bindValues);
		return {
			rowsAffected: result.changes,
			lastInsertId: result.lastInsertRowid
		};
	}

	async select<T>(query: string, bindValues: SqlValue[] = []): Promise<T> {
		return this.database.query(query).all(...bindValues) as T;
	}

	async executeBatch(statements: SqlStatement[]): Promise<void> {
		this.database.exec('BEGIN IMMEDIATE');
		try {
			for (const statement of statements) {
				this.database.query(statement.query).run(...(statement.bindValues ?? []));
			}
			this.database.exec('COMMIT');
		} catch (error) {
			this.database.exec('ROLLBACK');
			throw error;
		}
	}

	close() {
		this.database.close();
	}
}

function createTestRepository() {
	const database = new Database(':memory:');
	const migrationsUrl = new URL('../migrations/', import.meta.url);
	for (const filename of readdirSync(migrationsUrl).sort()) {
		const migration = readFileSync(new URL(filename, migrationsUrl), 'utf8');
		database.exec(migration);
	}
	const client = new BunSqliteDatabase(database);
	const repository = createCuePadRepository(() => Promise.resolve(client));
	return { client, repository };
}

describe('CuePad repository', () => {
	test('stores and reads projects, inbox cards, tags, and settings', async () => {
		const { client, repository } = createTestRepository();
		try {
			const project = await repository.createProject({ color: '#facc15', name: null, icon: null });
			const card = await repository.createCard({ projectId: null, title: null, body: 'draft body' });
			const tag = await repository.createTag('prompt');
			const defaultSettings = await repository.getSettings();

			expect(defaultSettings.theme).toBe('system');
			expect(defaultSettings.globalShortcut).toBeNull();

			await repository.addTagToCard(card.id, tag.id);
			await repository.setSetting('theme', 'dark');

			expect(await repository.getProject(project.id)).toMatchObject({
				name: null,
				icon: null,
				color: '#facc15'
			});
			expect(await repository.listProjects()).toHaveLength(1);
			expect(INBOX_PROJECT).toMatchObject({ kind: 'inbox', id: null, isVirtual: true });

			const inboxCards = await repository.listCards({ projectId: null });
			expect(inboxCards).toHaveLength(1);
			expect(inboxCards[0]).toMatchObject({
				projectId: null,
				title: null,
				body: 'draft body',
				numbering: 'none'
			});
			expect(inboxCards[0].createdAt).toBe(inboxCards[0].updatedAt);

			const renumbered = await repository.updateCard(card.id, { numbering: 'alpha' });
			expect(renumbered?.numbering).toBe('alpha');

			const tags = await repository.listTagsForCard(card.id);
			expect(tags).toHaveLength(1);
			expect(tags[0]).toMatchObject({ id: tag.id, name: 'prompt' });

			expect((await repository.getSettings()).theme).toBe('dark');
			expect((await repository.getAppSetting('theme'))?.value).toBe('dark');
		} finally {
			client.close();
		}
	});

	test('v4 保留旧 project favorite 值为 pin，并在重启后持久化更新', async () => {
		const directory = mkdtempSync(join(tmpdir(), 'cuepad-project-pin-'));
		const databasePath = join(directory, 'cuepad.sqlite');
		const migrationsUrl = new URL('../migrations/', import.meta.url);
		try {
			const database = new Database(databasePath);
			for (const filename of readdirSync(migrationsUrl).sort().slice(0, 3)) {
				database.exec(readFileSync(new URL(filename, migrationsUrl), 'utf8'));
			}
			database
				.query(
					`INSERT INTO projects
					 (name, color, sort_order, is_favorite, created_at, updated_at)
					 VALUES ('Pinned before v4', '#4f8ce8', 0, 1, 1, 1)`
				)
				.run();
			database.exec(readFileSync(new URL('004_project_pinning.sql', migrationsUrl), 'utf8'));
			database.close();

			const firstClient = new BunSqliteDatabase(new Database(databasePath));
			const firstRepository = createCuePadRepository(() => Promise.resolve(firstClient));
			const migrated = (await firstRepository.listProjects())[0];
			expect(migrated).toMatchObject({ isPinned: true });
			await firstRepository.setProjectPinned(migrated.id, false);
			firstClient.close();

			const restartedClient = new BunSqliteDatabase(new Database(databasePath));
			const restartedRepository = createCuePadRepository(() => Promise.resolve(restartedClient));
			expect(await restartedRepository.getProject(migrated.id)).toMatchObject({ isPinned: false });
			restartedClient.close();
		} finally {
			rmSync(directory, { recursive: true, force: true });
		}
	});

	test('restores only cards deleted by the same project batch', async () => {
		const { client, repository } = createTestRepository();
		try {
			const project = await repository.createProject({ color: '#60a5fa', name: 'Work' });
			const projectDeletedCard = await repository.createCard({ projectId: project.id, body: 'project batch' });
			const separatelyDeletedCard = await repository.createCard({ projectId: project.id, body: 'card batch' });

			const cardDelete = await repository.softDeleteCard(separatelyDeletedCard.id);
			const projectDelete = await repository.softDeleteProject(project.id);
			expect(cardDelete).not.toBeNull();
			expect(projectDelete).not.toBeNull();

			expect(await repository.getCard(projectDeletedCard.id, true)).toMatchObject({
				deleteBatchId: projectDelete?.batchId,
				deleteSource: 'project',
				deleteSourceId: project.id
			});

			await repository.restoreProject(project.id);

			expect(await repository.getProject(project.id)).toMatchObject({ deletedAt: null });
			expect(await repository.getCard(projectDeletedCard.id)).toMatchObject({ deletedAt: null });
			expect(await repository.getCard(separatelyDeletedCard.id)).toBeNull();
			expect(await repository.getCard(separatelyDeletedCard.id, true)).toMatchObject({
				deleteBatchId: cardDelete?.batchId,
				deleteSource: 'card'
			});
		} finally {
			client.close();
		}
	});

	test('permanently deletes a trashed project together with its batch cards only', async () => {
		const { client, repository } = createTestRepository();
		try {
			const project = await repository.createProject({ color: '#60a5fa', name: 'Work' });
			const batchCard = await repository.createCard({ projectId: project.id, body: 'goes with project' });
			const soloCard = await repository.createCard({ projectId: project.id, body: 'deleted alone' });
			const inboxCard = await repository.createCard({ body: 'stays' });

			await repository.softDeleteCard(soloCard.id);
			await repository.softDeleteProject(project.id);
			await repository.deleteProjectPermanently(project.id);

			expect(await repository.getProject(project.id, true)).toBeNull();
			expect(await repository.getCard(batchCard.id, true)).toBeNull();
			expect(await repository.getCard(soloCard.id, true)).not.toBeNull();
			expect(await repository.getCard(inboxCard.id)).not.toBeNull();

			// permanent delete is a no-op for projects that are not in the trash
			const activeProject = await repository.createProject({ color: '#facc15' });
			await repository.deleteProjectPermanently(activeProject.id);
			expect(await repository.getProject(activeProject.id)).not.toBeNull();
		} finally {
			client.close();
		}
	});

	test('restoring a card whose project is still deleted moves it to the inbox', async () => {
		const { client, repository } = createTestRepository();
		try {
			const project = await repository.createProject({ color: '#60a5fa' });
			const card = await repository.createCard({ projectId: project.id });

			await repository.softDeleteCard(card.id);
			await repository.softDeleteProject(project.id);
			const restored = await repository.restoreCard(card.id);

			expect(restored).toMatchObject({ deletedAt: null, projectId: null });
		} finally {
			client.close();
		}
	});

	test('reorders projects and cards by explicit id order', async () => {
		const { client, repository } = createTestRepository();
		try {
			const first = await repository.createProject({ color: '#111111', sortOrder: 0 });
			const second = await repository.createProject({ color: '#222222', sortOrder: 1 });
			const third = await repository.createProject({ color: '#333333', sortOrder: 2 });

			await repository.reorderProjects([third.id, first.id, second.id]);
			expect((await repository.listProjects()).map((project) => project.id)).toEqual([
				third.id,
				first.id,
				second.id
			]);

			const cardA = await repository.createCard({ sortOrder: 0 });
			const cardB = await repository.createCard({ sortOrder: 1 });
			await repository.reorderCards([cardB.id, cardA.id]);
			expect((await repository.listCards({ projectId: null })).map((card) => card.id)).toEqual([
				cardB.id,
				cardA.id
			]);
		} finally {
			client.close();
		}
	});

	test('setTagColor 更新颜色并可清空，新建标签默认无色', async () => {
		const { client, repository } = createTestRepository();
		try {
			const tag = await repository.createTag('prompt');
			expect(tag.color).toBeNull();

			const colored = await repository.setTagColor(tag.id, '#b8c7ba');
			expect(colored).toMatchObject({ id: tag.id, color: '#b8c7ba' });
			expect((await repository.listTags())[0].color).toBe('#b8c7ba');

			const cleared = await repository.setTagColor(tag.id, null);
			expect(cleared?.color).toBeNull();
			expect(await repository.setTagColor(999, '#b8c7ba')).toBeNull();
		} finally {
			client.close();
		}
	});

	test('createProject 失败时抛错（上层据此保留弹窗与输入，不静默假成功）', async () => {
		const { client, repository } = createTestRepository();
		try {
			// 绕过类型模拟运行时失败：color 列 NOT NULL，写入必须报错而非吞掉
			await expect(
				repository.createProject({ color: null } as unknown as Parameters<typeof repository.createProject>[0])
			).rejects.toThrow();
			expect(await repository.listProjects()).toHaveLength(0);
		} finally {
			client.close();
		}
	});

	test('emptyTrash 只硬删软删除的项目与卡片，未删内容保留', async () => {
		const { client, repository } = createTestRepository();
		try {
			const project = await repository.createProject({ color: '#4f8ce8' });
			const keep = await repository.createCard({ title: 'keep' });
			const gone = await repository.createCard({ title: 'gone' });
			await repository.softDeleteProject(project.id);
			await repository.softDeleteCard(gone.id);

			await repository.emptyTrash();

			const trash = await repository.listTrash();
			expect(trash.projects).toHaveLength(0);
			expect(trash.cards).toHaveLength(0);
			expect(await repository.getCard(keep.id)).toMatchObject({ title: 'keep' });
			expect(await repository.getProject(project.id, true)).toBeNull();
		} finally {
			client.close();
		}
	});

	test('deduplicates tags globally by name', async () => {
		const { client, repository } = createTestRepository();
		try {
			const first = await repository.createTag('prompt');
			const second = await repository.createTag('prompt');

			expect(second.id).toBe(first.id);
			expect(await repository.listTags()).toHaveLength(1);

			const card = await repository.createCard({});
			await repository.addTagToCard(card.id, first.id);
			await repository.addTagToCard(card.id, second.id);
			expect(await repository.listTagsForCard(card.id)).toHaveLength(1);

			await repository.removeTagFromCard(card.id, first.id);
			expect(await repository.listTagsForCard(card.id)).toHaveLength(0);
		} finally {
			client.close();
		}
	});

	test('searches projects, card title/body, and tag names with literal LIKE escaping', async () => {
		const { client, repository } = createTestRepository();
		try {
			const project = await repository.createProject({ color: '#60a5fa', name: 'Prompt Library' });
			const titled = await repository.createCard({ title: 'Prompt draft' });
			const bodied = await repository.createCard({ body: 'first line\nprompt in body' });
			const tagged = await repository.createCard({ title: 'untitled' });
			const tag = await repository.createTag('prompt-tag');
			await repository.addTagToCard(tagged.id, tag.id);
			const literal = await repository.createCard({ title: 'discount 50%_off' });

			const found = await repository.searchContent('prompt');
			expect(found.projects.map((item) => item.id)).toEqual([project.id]);
			expect(found.cards.map((item) => item.id).sort()).toEqual(
				[titled.id, bodied.id, tagged.id].sort()
			);

			// % 和 _ 按字面匹配，不作通配符
			expect((await repository.searchContent('50%_off')).cards.map((item) => item.id)).toEqual([
				literal.id
			]);
			expect((await repository.searchContent('50%X')).cards).toHaveLength(0);

			expect(await repository.searchContent('   ')).toMatchObject({ projects: [], cards: [] });
		} finally {
			client.close();
		}
	});

	test('trash search only sees deleted content and main search excludes it', async () => {
		const { client, repository } = createTestRepository();
		try {
			const keep = await repository.createCard({ title: 'prompt kept' });
			const trashed = await repository.createCard({ title: 'prompt trashed' });
			await repository.softDeleteCard(trashed.id);

			const main = await repository.searchContent('prompt');
			expect(main.cards.map((item) => item.id)).toEqual([keep.id]);

			const trash = await repository.searchContent('prompt', { deleted: true });
			expect(trash.cards.map((item) => item.id)).toEqual([trashed.id]);
		} finally {
			client.close();
		}
	});

	test('permanently deleting a card also removes its tag links', async () => {
		const { client, repository } = createTestRepository();
		try {
			const card = await repository.createCard({ title: 'temp' });
			const tag = await repository.createTag('cleanup');
			await repository.addTagToCard(card.id, tag.id);

			await repository.deleteCardPermanently(card.id);

			expect(await repository.getCard(card.id, true)).toBeNull();
			const links = await client.select<{ card_id: number }[]>(
				`SELECT card_id FROM card_tags WHERE card_id = $1`,
				[card.id]
			);
			expect(links).toHaveLength(0);
			expect(await repository.listTags()).toHaveLength(1);
		} finally {
			client.close();
		}
	});

	test('tasks schema stays minimal and task CRUD preserves front insertion', async () => {
		const { client, repository } = createTestRepository();
		try {
			const columns = await client.select<{ name: string }[]>(`PRAGMA table_info(tasks)`);
			expect(columns.map((column) => column.name)).toEqual([
				'id',
				'content',
				'project_id',
				'sort_order',
				'completed_at',
				'created_at',
				'updated_at'
			]);
			const indexes = await client.select<{ name: string }[]>(`PRAGMA index_list(tasks)`);
			expect(indexes.map((index) => index.name).sort()).toEqual([
				'idx_tasks_active_sort',
				'idx_tasks_project'
			]);

			const project = await repository.createProject({ color: '#4f8ce8', name: 'Alpha' });
			await expect(repository.createTask({ content: '\n\t' })).rejects.toThrow();
			const first = await repository.createTask({ content: '第一件事', projectId: project.id });
			const second = await repository.createTask({ content: '第二件事' });

			expect((await repository.listTasks()).map((task) => task.id)).toEqual([
				second.id,
				first.id
			]);
			expect(second.sortOrder).toBe(first.sortOrder - 1);
			expect(first.createdAt).toBe(first.updatedAt);

			const updated = await repository.updateTask(first.id, {
				content: '第一件事（已改）',
				projectId: null
			});
			expect(updated).toMatchObject({ content: '第一件事（已改）', projectId: null });
			await expect(repository.updateTask(first.id, { content: '\n\t  ' })).rejects.toThrow();
			expect(await repository.updateTask(999, { content: '不存在' })).toBeNull();

			await repository.deleteTaskPermanently(second.id);
			expect((await repository.listTasks()).map((task) => task.id)).toEqual([first.id]);
		} finally {
			client.close();
		}
	});

	test('tasks reorder active items only and completed items sort newest first', async () => {
		const { client, repository } = createTestRepository();
		try {
			const first = await repository.createTask({ content: '一' });
			const second = await repository.createTask({ content: '二' });
			const third = await repository.createTask({ content: '三' });

			await repository.updateTask(first.id, { completedAt: 100 });
			await repository.updateTask(third.id, { completedAt: 200 });
			expect((await repository.listTasks()).map((task) => task.id)).toEqual([
				second.id,
				third.id,
				first.id
			]);

			await repository.updateTask(third.id, { completedAt: null });
			await repository.reorderTasks([second.id, third.id]);
			expect((await repository.listTasks()).map((task) => task.id)).toEqual([
				second.id,
				third.id,
				first.id
			]);

			await repository.updateTask(second.id, { completedAt: 300 });
			await repository.updateTask(second.id, { completedAt: null });
			expect((await repository.listTasks()).map((task) => task.id)).toEqual([
				second.id,
				third.id,
				first.id
			]);
		} finally {
			client.close();
		}
	});

	test('task reorder keeps completed base slots for later restore', async () => {
		const { client, repository } = createTestRepository();
		try {
			const first = await repository.createTask({ content: '一' });
			const middle = await repository.createTask({ content: '二' });
			const last = await repository.createTask({ content: '三' });
			await repository.updateTask(middle.id, { completedAt: 100 });

			await repository.reorderTasks([first.id, last.id]);
			await repository.updateTask(middle.id, { completedAt: null });

			expect((await repository.listTasks()).map((task) => task.id)).toEqual([
				first.id,
				middle.id,
				last.id
			]);
		} finally {
			client.close();
		}
	});

	test('task project link survives soft delete and clears on hard delete or empty trash', async () => {
		const { client, repository } = createTestRepository();
		try {
			const project = await repository.createProject({ color: '#69b483', name: 'Beta' });
			const task = await repository.createTask({ content: '关联任务', projectId: project.id });

			await repository.softDeleteProject(project.id);
			expect((await repository.listTasks())[0].projectId).toBe(project.id);
			await repository.restoreProject(project.id);
			expect((await repository.listTasks())[0].projectId).toBe(project.id);

			await repository.softDeleteProject(project.id);
			await repository.deleteProjectPermanently(project.id);
			expect((await repository.listTasks())[0].projectId).toBeNull();

			const emptiedProject = await repository.createProject({ color: '#e8a65a' });
			const emptiedTask = await repository.createTask({
				content: '清空关联',
				projectId: emptiedProject.id
			});
			await repository.softDeleteProject(emptiedProject.id);
			await repository.emptyTrash();
			expect((await repository.listTasks()).find((item) => item.id === emptiedTask.id)?.projectId).toBeNull();
			expect((await repository.listTasks()).find((item) => item.id === task.id)?.projectId).toBeNull();
		} finally {
			client.close();
		}
	});
});
