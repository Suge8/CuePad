import { browser, expect } from '@wdio/globals';

const FIXTURE_KEY = 'cuepad:wdio-workspace-fixture';

type BrowserAction =
	| { kind: 'click'; selector: string }
	| { kind: 'drag'; source: string; target: string; targetY?: number };
type ProjectState = { id: number; sort_order: number; is_pinned: number };
type CardState = { id: number; sort_order: number; is_favorite: number };
type TaskState = {
	id: number;
	content: string;
	project_id: number | null;
	sort_order: number;
	completed_at: number | null;
};

type TauriWindow = Window & {
	__TAURI_INTERNALS__: {
		invoke: (command: string, args?: Record<string, unknown>) => Promise<unknown>;
	};
};

async function invokeSql<T>(command: 'select', query: string, values: unknown[]): Promise<T> {
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

function selectSql<T>(query: string, values: unknown[] = []): Promise<T> {
	return invokeSql('select', query, values);
}

async function waitForSelector(selector: string, present = true) {
	return browser.executeAsync<boolean>(
		(cssSelector, expected, done) => {
			const matches = () => Boolean(document.querySelector(cssSelector)) === expected;
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
		present
	);
}

async function click(selector: string) {
	const found = await browser.execute((cssSelector) => {
		const button = document.querySelector<HTMLButtonElement>(cssSelector);
		button?.click();
		return Boolean(button);
	}, selector);
	if (!found) throw new Error(`找不到 ${selector}`);
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

async function act(action: BrowserAction) {
	const failure = await browser.execute((operation) => {
		if (operation.kind === 'click') {
			const button = document.querySelector<HTMLButtonElement>(operation.selector);
			if (!button) return `找不到 ${operation.selector}`;
			button.click();
			return null;
		}
		const source = document.querySelector<HTMLElement>(operation.source);
		const target = document.querySelector<HTMLElement>(operation.target);
		if (!source || !target) return `找不到拖拽元素 ${operation.source}`;
		const sourceBox = source.getBoundingClientRect();
		const targetBox = target.getBoundingClientRect();
		const start = { x: sourceBox.x + sourceBox.width * 0.35, y: sourceBox.y + sourceBox.height * 0.5 };
		const end = {
			x: targetBox.x + targetBox.width * 0.05,
			y: targetBox.y + targetBox.height * (operation.targetY ?? 0.8)
		};
		source.dispatchEvent(
			new PointerEvent('pointerdown', {
				bubbles: true,
				buttons: 1,
				clientX: start.x,
				clientY: start.y,
				isPrimary: true,
				pointerId: 1,
				pointerType: 'touch'
			})
		);
		const move = () => document.dispatchEvent(
			new PointerEvent('pointermove', {
				bubbles: true,
				buttons: 1,
				clientX: end.x,
				clientY: end.y,
				isPrimary: true,
				pointerId: 1,
				pointerType: 'touch'
			})
		);
		if (source.closest('[data-task-id]')) {
			move();
			document.dispatchEvent(
				new PointerEvent('pointerup', {
					bubbles: true,
					clientX: end.x,
					clientY: end.y,
					isPrimary: true,
					pointerId: 1,
					pointerType: 'touch'
				})
			);
			return null;
		}
		move();
		// 项目/卡片仍由 sveltednd 处理；1×1 窗直接派发其 pointer drop 入口。
		target.dispatchEvent(new CustomEvent('pointerdrop-on-container', { bubbles: true }));
		queueMicrotask(() => source.dispatchEvent(new DragEvent('dragend', { bubbles: true })));
		return null;
	}, action);
	if (failure) throw new Error(failure);
}

/** WDIO 的隔离 JS world 无法订阅被冻结的 Tauri invoke；仅对真实 SQLite 最终状态做有界观察。 */
async function waitForDatabase(check: () => Promise<boolean>, message: string) {
	await browser.waitUntil(check, { timeout: 5_000, interval: 50, timeoutMsg: message });
}

async function dismissWelcome() {
	const open = await browser.execute(() => Boolean(document.querySelector('.welcome-card')));
	if (open) await click('.welcome-card button');
}

async function ensureBoard() {
	if (await browser.execute(() => Boolean(document.querySelector('.board')))) return;
	await click('.hero-start');
	expect(await waitForSelector('.board')).toBe(true);
	await browser.execute(() => window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })));
}

async function createProject(name: string): Promise<number> {
	await click('.new-project');
	expect(await waitForSelector('.dialog-card')).toBe(true);
	await browser.execute((projectName) => {
		const input = document.querySelector<HTMLInputElement>('.dialog-card input');
		if (!input) throw new Error('找不到项目名称输入框');
		input.value = projectName;
		input.dispatchEvent(new InputEvent('input', { bubbles: true, data: projectName }));
		document.querySelector<HTMLButtonElement>('.dialog-card .submit')?.click();
	}, name);
	return browser.executeAsync<number>(
		(projectName, done) => {
			const find = () => {
				const item = [...document.querySelectorAll<HTMLElement>('[data-project-id]')].find(
					(element) => element.querySelector('strong')?.textContent === projectName
				);
				return Number(item?.dataset.projectId) || 0;
			};
			const current = find();
			if (current) {
				done(current);
				return;
			}
			const timeout = setTimeout(() => {
				observer.disconnect();
				done(0);
			}, 10_000);
			const observer = new MutationObserver(() => {
				const id = find();
				if (!id) return;
				clearTimeout(timeout);
				observer.disconnect();
				done(id);
			});
			observer.observe(document.body, { childList: true, subtree: true });
		},
		name
	);
}

async function createCard(): Promise<number> {
	const before = await browser.execute(() =>
		[...document.querySelectorAll<HTMLElement>('[data-card-id]')].map((element) => Number(element.dataset.cardId))
	);
	await click('.ghost-card');
	const cardId = await browser.executeAsync<number>(
		(known, done) => {
			const find = () =>
				[...document.querySelectorAll<HTMLElement>('[data-card-id]')]
					.map((element) => Number(element.dataset.cardId))
					.find((id) => !known.includes(id)) ?? 0;
			const current = find();
			if (current) {
				done(current);
				return;
			}
			const timeout = setTimeout(() => {
				observer.disconnect();
				done(0);
			}, 10_000);
			const observer = new MutationObserver(() => {
				const id = find();
				if (!id) return;
				clearTimeout(timeout);
				observer.disconnect();
				done(id);
			});
			observer.observe(document.body, { childList: true, subtree: true });
		},
		before
	);
	await browser.execute(() => window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })));
	if (!cardId) throw new Error('新卡未进入卡片墙');
	return cardId;
}

async function createTask(content: string): Promise<number> {
	await ensureTaskPanel();
	await click('[data-task-add-trigger]');
	expect(await waitForSelector('.task-create')).toBe(true);
	await browser.execute((taskContent) => {
		const input = document.querySelector<HTMLInputElement>('.task-create input');
		if (!input) throw new Error('找不到任务输入框');
		input.value = taskContent;
		input.dispatchEvent(new InputEvent('input', { bubbles: true, data: taskContent }));
		document.querySelector<HTMLButtonElement>('.task-create button[type="submit"]')?.click();
	}, content);
	return browser.executeAsync<number>(
		(taskContent, done) => {
			const find = () => {
				const row = [...document.querySelectorAll<HTMLElement>('[data-task-id]')].find(
					(element) => element.textContent?.includes(taskContent)
				);
				return Number(row?.dataset.taskId) || 0;
			};
			const current = find();
			if (current) {
				done(current);
				return;
			}
			const timeout = setTimeout(() => {
				observer.disconnect();
				done(0);
			}, 10_000);
			const observer = new MutationObserver(() => {
				const id = find();
				if (!id) return;
				clearTimeout(timeout);
				observer.disconnect();
				done(id);
			});
			observer.observe(document.body, { childList: true, subtree: true });
		},
		content
	);
}

function projectState(ids: number[]): Promise<ProjectState[]> {
	return selectSql(
		'SELECT id, sort_order, is_pinned FROM projects WHERE id IN ($1, $2) ORDER BY sort_order',
		ids
	);
}

function cardState(ids: number[]): Promise<CardState[]> {
	return selectSql(
		'SELECT id, sort_order, is_favorite FROM cards WHERE id IN ($1, $2) ORDER BY sort_order',
		ids
	);
}

function taskState(ids: number[]): Promise<TaskState[]> {
	return selectSql(
		`SELECT id, content, project_id, sort_order, completed_at
		 FROM tasks WHERE id IN ($1, $2) ORDER BY sort_order`,
		ids
	);
}

describe('真实 Tauri 工作区交互链路', () => {
	it('Pin、Star 与同分区拖拽经过真实 WKWebView 和 SQLite', async () => {
		await dismissWelcome();
		await ensureBoard();
		const projectAlpha = await createProject('WDIO Alpha');
		const projectBeta = await createProject('WDIO Beta');
		expect(projectAlpha).toBeGreaterThan(0);
		expect(projectBeta).toBeGreaterThan(0);
		await click(`[data-project-id="${projectAlpha}"] .project-select`);
		const firstCard = await createCard();
		const secondCard = await createCard();
		const projectIds = [projectAlpha, projectBeta];
		const cardIds = [firstCard, secondCard];

		await act({
			kind: 'click',
			selector: `[data-project-id="${projectAlpha}"] [aria-label^="更多项目操作："]`
		});
		await act({ kind: 'click', selector: '[data-project-pin-action]' });
		await waitForDatabase(
			async () => (await projectState(projectIds)).find((project) => project.id === projectAlpha)?.is_pinned === 1,
			'项目置顶未写入真实 SQLite'
		);
		await act({
			kind: 'click',
			selector: `[data-project-id="${projectAlpha}"] [aria-label^="更多项目操作："]`
		});
		await act({ kind: 'click', selector: '[data-project-pin-action]' });
		await waitForDatabase(
			async () => (await projectState(projectIds)).find((project) => project.id === projectAlpha)?.is_pinned === 0,
			'项目取消置顶未写入真实 SQLite'
		);

		await act({
			kind: 'drag',
			source: `[data-project-id="${projectBeta}"] .project-select`,
			target: `[data-project-id="${projectAlpha}"]`
		});
		await waitForDatabase(
			async () => (await projectState(projectIds)).map((project) => project.id).join() === `${projectBeta},${projectAlpha}`,
			'项目拖拽顺序未写入真实 SQLite'
		);

		await act({
			kind: 'click',
			selector: `[data-card-id="${firstCard}"] [aria-label="收藏"]`
		});
		await waitForDatabase(
			async () => (await cardState(cardIds)).find((card) => card.id === firstCard)?.is_favorite === 1,
			'卡片收藏未写入真实 SQLite'
		);
		await act({
			kind: 'click',
			selector: `[data-card-id="${firstCard}"] [aria-label="取消收藏"]`
		});
		await waitForDatabase(
			async () => (await cardState(cardIds)).find((card) => card.id === firstCard)?.is_favorite === 0,
			'卡片取消收藏未写入真实 SQLite'
		);

		const initialCards = await browser.execute(() =>
			[...document.querySelectorAll<HTMLElement>('.grid > [data-card-id]')].map((element) => Number(element.dataset.cardId))
		);
		const [targetCard, sourceCard] = initialCards.filter((id) => cardIds.includes(id));
		await act({
			kind: 'drag',
			source: `[data-card-id="${sourceCard}"] .card-hit`,
			target: `[data-card-id="${targetCard}"] .card`
		});
		await waitForDatabase(
			async () => (await cardState(cardIds)).map((card) => card.id).join() === `${sourceCard},${targetCard}`,
			'卡片拖拽顺序未写入真实 SQLite'
		);

		// v5 migration + TaskStack 必须走真实 SQLite：创建、分配、完成/恢复与纵向重排
		const firstTask = await createTask('WDIO 第一条任务');
		const secondTask = await createTask('WDIO 第二条任务');
		expect(firstTask).toBeGreaterThan(0);
		expect(secondTask).toBeGreaterThan(0);
		const taskIds = [firstTask, secondTask];
		await click(`[data-task-id="${secondTask}"] [aria-label="未分配项目"]`);
		expect(await waitForSelector('[data-task-project-menu]')).toBe(true);
		const assigned = await browser.execute((projectName) => {
			const option = [...document.querySelectorAll<HTMLButtonElement>('.project-option')].find(
				(button) => button.textContent?.trim() === projectName
			);
			option?.click();
			return Boolean(option);
		}, 'WDIO Beta');
		expect(assigned).toBe(true);
		await waitForDatabase(
			async () => (await taskState(taskIds)).find((task) => task.id === secondTask)?.project_id === projectBeta,
			'任务项目分配未写入真实 SQLite'
		);

		await click(`[data-task-id="${firstTask}"] .task-check`);
		await waitForDatabase(
			async () => (await taskState(taskIds)).find((task) => task.id === firstTask)?.completed_at !== null,
			'任务完成状态未写入真实 SQLite'
		);
		await click('.completed-toggle');
		expect(await waitForSelector(`[data-task-id="${firstTask}"][data-task-state="completed"]`)).toBe(true);
		await click(`[data-task-id="${firstTask}"][data-task-state="completed"] .task-check`);
		await waitForDatabase(
			async () => (await taskState(taskIds)).find((task) => task.id === firstTask)?.completed_at === null,
			'任务恢复状态未写入真实 SQLite'
		);

		await act({
			kind: 'drag',
			source: `[data-task-id="${secondTask}"] .task-copy`,
			target: `[data-task-id="${firstTask}"]`
		});
		await waitForDatabase(
			async () => (await taskState(taskIds)).map((task) => task.id).join() === `${firstTask},${secondTask}`,
			'任务向下拖拽顺序未写入真实 SQLite'
		);
		await act({
			kind: 'drag',
			source: `[data-task-id="${secondTask}"] .task-copy`,
			target: `[data-task-id="${firstTask}"]`,
			targetY: 0.2
		});
		await waitForDatabase(
			async () => (await taskState(taskIds)).map((task) => task.id).join() === `${secondTask},${firstTask}`,
			'任务向上拖拽顺序未写入真实 SQLite'
		);
		await act({
			kind: 'drag',
			source: `[data-task-id="${secondTask}"] .task-copy`,
			target: `[data-task-id="${firstTask}"]`
		});
		await waitForDatabase(
			async () => (await taskState(taskIds)).map((task) => task.id).join() === `${firstTask},${secondTask}`,
			'任务复原顺序未写入真实 SQLite'
		);

		await browser.execute((key, fixture) => {
			localStorage.setItem(key, JSON.stringify(fixture));
		}, FIXTURE_KEY, {
			projectAlpha,
			projectIds,
			cardIds,
			taskIds,
			projectOrder: [projectBeta, projectAlpha],
			cardOrder: [sourceCard, targetCard],
			taskOrder: [firstTask, secondTask]
		});
	});
});
