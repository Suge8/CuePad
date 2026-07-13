import { browser, expect } from '@wdio/globals';

const FIXTURE_KEY = 'cuepad:wdio-workspace-fixture';

type Fixture = {
	projectAlpha: number;
	projectIds: number[];
	cardIds: number[];
	taskIds: number[];
	projectOrder: number[];
	cardOrder: number[];
	taskOrder: number[];
};
type ProjectState = { id: number; sort_order: number; is_pinned: number };
type CardState = { id: number; sort_order: number; is_favorite: number };
type TaskState = {
	id: number;
	content: string;
	project_id: number | null;
	completed_at: number | null;
};
type TauriWindow = Window & {
	__TAURI_INTERNALS__: {
		invoke: (command: string, args?: Record<string, unknown>) => Promise<unknown>;
	};
};

async function invokeSql<T>(command: 'execute' | 'select', query: string, values: unknown[]) {
	const result = await browser.executeAsync<{ value?: T; failure?: string }>(
		(sqlCommand, statement, parameters, done) => {
			(window as TauriWindow).__TAURI_INTERNALS__
				.invoke(`plugin:sql|${sqlCommand}`, {
					db: 'sqlite:cuepad.db',
					query: statement,
					values: parameters
				})
				.then(
					(value) => done({ value: value as T }),
					(error) => done({ failure: String(error) })
				);
		},
		command,
		query,
		values
	);
	if (result.failure) throw new Error(result.failure);
	return result.value as T;
}

async function waitForText(selector: string, text: string) {
	return browser.executeAsync<boolean>(
		(cssSelector, expected, done) => {
			const matches = () =>
				[...document.querySelectorAll(cssSelector)].some(
					(element) => element.textContent?.trim() === expected
				);
			if (matches()) {
				done(true);
				return;
			}
			const timeout = setTimeout(() => {
				observer.disconnect();
				done(false);
			}, 10_000);
			const observer = new MutationObserver(() => {
				if (!matches()) return;
				clearTimeout(timeout);
				observer.disconnect();
				done(true);
			});
			observer.observe(document.body, { childList: true, subtree: true });
		},
		selector,
		text
	);
}

async function ensureTaskPanel() {
	const ready = await browser.executeAsync<boolean>((done) => {
		let finished = false;
		const finish = (value: boolean) => {
			if (finished) return;
			finished = true;
			clearTimeout(timeout);
			observer.disconnect();
			done(value);
		};
		const advance = () => {
			const trigger = document.querySelector<HTMLButtonElement>('[data-task-narrow-trigger]');
			if (
				trigger &&
				getComputedStyle(trigger).display !== 'none' &&
				trigger.getAttribute('aria-expanded') !== 'true'
			) trigger.click();
			if (document.querySelector('[data-task-add-trigger]')) finish(true);
		};
		const timeout = setTimeout(() => finish(false), 10_000);
		const observer = new MutationObserver(advance);
		observer.observe(document.body, { childList: true, subtree: true });
		advance();
	});
	if (!ready) throw new Error('任务面板未就绪');
}

let fixture: Fixture | null = null;

describe('真实 Tauri 重启恢复', () => {
	before(async () => {
		fixture = await browser.execute((key) => {
			const value = localStorage.getItem(key);
			return value ? (JSON.parse(value) as Fixture) : null;
		}, FIXTURE_KEY);
		if (!fixture) throw new Error('上一真实 Tauri 交互未留下恢复 fixture');
	});

	after(async () => {
		if (!fixture) return;
		await invokeSql('execute', 'DELETE FROM tasks WHERE id IN ($1, $2)', fixture.taskIds);
		await invokeSql('execute', 'DELETE FROM cards WHERE id IN ($1, $2)', fixture.cardIds);
		await invokeSql('execute', 'DELETE FROM projects WHERE id IN ($1, $2)', fixture.projectIds);
		await browser.execute((key) => {
			localStorage.removeItem(key);
			localStorage.removeItem('cuepad:active-project');
		}, FIXTURE_KEY);
	});

	it('新进程恢复当前项目、手动顺序与 Pin/Star 最终状态', async () => {
		const current = fixture!;
		expect(await waitForText('h2', 'WDIO Alpha')).toBe(true);
		expect(await browser.execute(() => localStorage.getItem('cuepad:active-project'))).toBe(
			String(current.projectAlpha)
		);
		await ensureTaskPanel();
		const order = await browser.execute((projectIds, cardIds, taskIds) => ({
			projects: [...document.querySelectorAll<HTMLElement>('[data-project-id]')]
				.map((element) => Number(element.dataset.projectId))
				.filter((id) => projectIds.includes(id)),
			cards: [...document.querySelectorAll<HTMLElement>('[data-card-id]')]
				.map((element) => Number(element.dataset.cardId))
				.filter((id) => cardIds.includes(id)),
			tasks: [...document.querySelectorAll<HTMLElement>('[data-task-state="active"]')]
				.map((element) => Number(element.dataset.taskId))
				.filter((id) => taskIds.includes(id))
		}), current.projectIds, current.cardIds, current.taskIds);
		expect(order.projects).toEqual(current.projectOrder);
		expect(order.cards).toEqual(current.cardOrder);
		expect(order.tasks).toEqual(current.taskOrder);

		const projects = await invokeSql<ProjectState[]>(
			'select',
			'SELECT id, sort_order, is_pinned FROM projects WHERE id IN ($1, $2) ORDER BY sort_order',
			current.projectIds
		);
		const cards = await invokeSql<CardState[]>(
			'select',
			'SELECT id, sort_order, is_favorite FROM cards WHERE id IN ($1, $2) ORDER BY sort_order',
			current.cardIds
		);
		const tasks = await invokeSql<TaskState[]>(
			'select',
			`SELECT id, content, project_id, completed_at
			 FROM tasks WHERE id IN ($1, $2) ORDER BY sort_order`,
			current.taskIds
		);
		expect(projects.map((project) => project.id)).toEqual(current.projectOrder);
		expect(projects.map((project) => project.is_pinned)).toEqual([0, 0]);
		expect(cards.map((card) => card.id)).toEqual(current.cardOrder);
		expect(cards.map((card) => card.is_favorite)).toEqual([0, 0]);
		expect(tasks.map((task) => task.id)).toEqual(current.taskOrder);
		expect(tasks.map((task) => task.content)).toEqual(['WDIO 第一条任务', 'WDIO 第二条任务']);
		expect(tasks.map((task) => task.completed_at)).toEqual([null, null]);
		expect(tasks.find((task) => task.id === current.taskOrder[1])?.project_id).toBe(
			current.projectOrder[0]
		);
	});
});
