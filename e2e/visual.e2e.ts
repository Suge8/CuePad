import { expect, test, type Locator, type Page } from '@playwright/test';

/**
 * 无头视觉验收：Playwright Chromium + 桌面桥 mock（e2e/bridge-mock.js）。
 * 覆盖 Electron 壳之外的视觉验收面：卡片墙、顶栏、六类弹层进出、
 * 深浅主题、沉浸编辑块装饰、减动降级。托盘/全局热键/真 SQL 由 Electron E2E 覆盖。
 * 文件后缀 .e2e.ts：避开 bun test 的 *.test/*.spec 匹配。
 */

// 产物目录由 e2e/run.ts 按调用生成，并发验收互不踩踏
const ARTIFACTS = process.env.CUEPAD_E2E_DIR;
if (!ARTIFACTS) throw new Error('请通过 `bun run test:e2e` 启动无头验收');

async function boot(
	page: Page,
	{ welcomed = true, activeProject = '1' }: { welcomed?: boolean; activeProject?: string | null } = {}
) {
	await page.addInitScript({ path: './e2e/animation-recorder.js' });
	await page.addInitScript({ path: './e2e/bridge-mock.js' });
	await page.addInitScript(
		({ welcomed, activeProject }) => {
			if (localStorage.getItem('cuepad:e2e-seeded')) return;
			if (welcomed) localStorage.setItem('cuepad:welcomed', '1');
			if (activeProject === null) localStorage.removeItem('cuepad:active-project');
			else localStorage.setItem('cuepad:active-project', activeProject);
			localStorage.setItem('cuepad:e2e-seeded', '1');
		},
		{ welcomed, activeProject }
	);
	await page.goto('/');
	// 首断言放宽超时：每个 E2E run 使用独立冷缓存，并发首页按需编译可能超过默认 5s
	await expect(page.getByRole('heading', { name: 'Alpha', exact: true })).toBeVisible({
		timeout: 20_000
	});
}

type AnimationRecord = { target: string; props: string[] };
type DispatchResult = { text: string; bundleId: string | null; submit: boolean; calls: number };
type SqlWrite = { query: string; values: unknown[] };

/** 先订阅 mock 外部边界的唯一完成事件，再触发操作；不读取可能属于上一操作的全局快照。 */
function nextMockEvent<T>(page: Page, eventName: string): Promise<T> {
	return page.evaluate(
		(name) =>
			new Promise<unknown>((resolve, reject) => {
				const listener = (event: Event) => {
					clearTimeout(timeout);
					resolve((event as CustomEvent).detail);
				};
				const timeout = setTimeout(() => {
					window.removeEventListener(name, listener);
					reject(new Error(`等待 ${name} 超时`));
				}, 5_000);
				window.addEventListener(name, listener, { once: true });
			}),
		eventName
	) as Promise<T>;
}

function nextMockEvents<T>(page: Page, eventName: string, count: number): Promise<T[]> {
	return page.evaluate(
		({ name, count }) =>
			new Promise<unknown[]>((resolve, reject) => {
				const events: unknown[] = [];
				const listener = (event: Event) => {
					events.push((event as CustomEvent).detail);
					if (events.length < count) return;
					clearTimeout(timeout);
					window.removeEventListener(name, listener);
					resolve(events);
				};
				const timeout = setTimeout(() => {
					window.removeEventListener(name, listener);
					reject(new Error(`等待 ${name} × ${count} 超时`));
				}, 5_000);
				window.addEventListener(name, listener);
			}),
		{ name: eventName, count }
	) as Promise<T[]>;
}

/** 读取某 class 元素的历史动画记录（由 animation-recorder.js 确定性记录，无采样竞态） */
function motionLog(page: Page, targetClass: string): Promise<AnimationRecord[]> {
	return page.evaluate(
		(cls) =>
			((window as unknown as { __ANIM_LOG__: { target: string; props: string[] }[] })
				.__ANIM_LOG__ ?? []).filter((record) => record.target.includes(cls)),
		targetClass
	);
}

/** 等两帧后再采样 computed style，避开 hover/press 过渡首帧仍处于起点的竞态。 */
function settled(page: Page) {
	return page.evaluate(
		() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
	);
}

async function openProjectActions(page: Page, project: Locator) {
	const trigger = project.getByRole('button', { name: /^更多项目操作：/ });
	await trigger.click();
	const menu = page.locator('.project-actions-menu');
	await expect(menu).toBeVisible();
	return menu;
}

/** 捕获项目切换中新卡首次布局与动画结束布局；MutationObserver 驱动，不轮询。 */
function cardMovementAfterInsert(page: Page, cardId: string) {
	return page.evaluate(
		(id) =>
			new Promise<{ x: number; y: number }>((resolve, reject) => {
				const cardStack = document.querySelector('.card-stack');
				if (!cardStack) {
					reject(new Error('卡片视图不存在'));
					return;
				}
				const timeout = setTimeout(() => {
					observer.disconnect();
					reject(new Error(`等待卡片 ${id} 进入超时`));
				}, 5_000);
				const observer = new MutationObserver(async () => {
					const card = document.querySelector(`[data-card-id="${id}"]`);
					if (!card) return;
					observer.disconnect();
					clearTimeout(timeout);
					const initial = card.getBoundingClientRect();
					await new Promise((nextFrame) => requestAnimationFrame(() => requestAnimationFrame(nextFrame)));
					await Promise.all(
						card.getAnimations({ subtree: true }).map((animation) => animation.finished.catch(() => undefined))
					);
					await new Promise((nextFrame) => requestAnimationFrame(() => requestAnimationFrame(nextFrame)));
					const final = card.getBoundingClientRect();
					resolve({ x: final.x - initial.x, y: final.y - initial.y });
				});
				observer.observe(cardStack, { childList: true, subtree: true });
			}),
		cardId
	);
}

/** 走 Chromium 真实鼠标链路；坐标刻意让 X/Y 判定相反。 */
async function dragBefore(
	page: Page,
	sourceHandle: Locator,
	target: Locator,
	expectedTargetClass?: RegExp
) {
	const sourceBox = await sourceHandle.boundingBox();
	const targetBox = await target.boundingBox();
	if (!sourceBox || !targetBox) throw new Error('拖拽元素不可见');
	await page.mouse.move(
		sourceBox.x + sourceBox.width * 0.35,
		sourceBox.y + sourceBox.height * 0.5
	);
	await page.mouse.down();
	await page.mouse.move(
		targetBox.x + targetBox.width * 0.05,
		targetBox.y + targetBox.height * 0.8,
		{ steps: 16 }
	);
	if (expectedTargetClass) await expect(target).toHaveClass(expectedTargetClass);
	await page.mouse.up();
}

async function verticalCenter(locator: Locator) {
	const box = await locator.boundingBox();
	if (!box) throw new Error('元素不可见');
	return box.y + box.height / 2;
}

async function moveTaskPointer(
	page: Page,
	sourceHandle: Locator,
	target: Locator,
	targetY: number
) {
	const sourceBox = await sourceHandle.boundingBox();
	const targetBox = await target.boundingBox();
	if (!sourceBox || !targetBox) throw new Error('任务拖拽元素不可见');
	await page.mouse.move(
		sourceBox.x + sourceBox.width * 0.5,
		sourceBox.y + sourceBox.height * 0.5
	);
	await page.mouse.down();
	await page.mouse.move(
		targetBox.x + targetBox.width * 0.5,
		targetBox.y + targetBox.height * targetY,
		{ steps: 8 }
	);
}

/** 等当前元素已有 WAAPI 动画完成：确保 intro 不会与随后触发的 outro 合并为一次反转 */
function finishMotion(locator: Locator) {
	return locator.evaluate(async (node) => {
		await Promise.all(node.getAnimations().map((animation) => animation.finished));
	});
}

function finishSubtreeMotion(locator: Locator) {
	return locator.evaluate(async (node) => {
		await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
		await Promise.all(
			node
				.getAnimations({ subtree: true })
				.map((animation) => animation.finished.catch(() => undefined))
		);
		await new Promise((resolve) => requestAnimationFrame(resolve));
	});
}

/** 当前记录数：作为后续「只看新增」断言的起点标记 */
async function motionMark(page: Page, targetClass: string): Promise<number> {
	return (await motionLog(page, targetClass)).length;
}

/**
 * 等待 targetClass 自第 since 条记录后新增含预期属性的过渡。
 * recorder 每次写日志都派发事件；这里先订阅再复查日志，避免「触发后立即读取」竞态，
 * 不用轮询。svelte 单次过渡会创建 dummy+正式两条同关键帧动画，退场仍须先 motionMark。
 */
async function expectMotionSince(
	page: Page,
	targetClass: string,
	since: number,
	property: 'transform' | 'opacity'
) {
	const added = await page.evaluate(
		({ targetClass, since, property }) =>
			new Promise<AnimationRecord[]>((resolve) => {
				const records = () =>
					((window as unknown as { __ANIM_LOG__: AnimationRecord[] }).__ANIM_LOG__ ?? [])
						.filter((record) => record.target.includes(targetClass))
						.slice(since);
				const finish = () => {
					const current = records();
					if (!current.some((record) => record.props.includes(property))) return;
					clearTimeout(timeout);
					window.removeEventListener('cuepad:animation', finish);
					resolve(current);
				};
				window.addEventListener('cuepad:animation', finish);
				const timeout = setTimeout(() => {
					window.removeEventListener('cuepad:animation', finish);
					resolve(records());
				}, 5_000);
				finish();
			}),
		{ targetClass, since, property }
	);
	expect(
		added.some((record) => record.props.includes(property)),
		`${targetClass} 自记录 #${since} 后应新增含 ${property} 的过渡，实际新增 ${JSON.stringify(added)}`
	).toBe(true);
}

test('首启欢迎卡进出场，卡片墙与精简顶栏（浅色）', async ({ page }) => {
	await boot(page, { welcomed: false });

	// 欢迎卡进场与退场（popRise：transform+opacity）
	const welcome = page.getByRole('dialog', { name: '欢迎' });
	await expect(welcome).toBeVisible();
	await expectMotionSince(page, 'welcome-card', 0, 'transform');
	await finishMotion(welcome);
	const welcomeMark = await motionMark(page, 'welcome-card');
	const welcomeOutro = expectMotionSince(page, 'welcome-card', welcomeMark, 'opacity');
	await page.getByRole('button', { name: '开始使用' }).click();
	await expect(welcome).toBeHidden();
	await welcomeOutro;

	// 顶栏只剩搜索 + 全局收藏 + 设置；正文只显示当前项目与一个 ghost 卡
	await expect(page.locator('.top-new')).toHaveCount(0);
	await expect(page.getByRole('button', { name: '全局收藏' })).toBeVisible();
	await expect(page.getByRole('button', { name: '设置' })).toBeVisible();
	const projectBar = page.getByRole('navigation', { name: '项目' });
	await expect(projectBar).toBeVisible();
	await expect(page.getByRole('heading', { name: 'Alpha', exact: true })).toBeVisible();
	await expect(page.getByText('当前项目', { exact: true })).toHaveCount(0);
	await expect(page.locator('.card h3', { hasText: 'Beta 提示词' })).toBeHidden();
	await expect(page.getByRole('button', { name: '新建卡片' })).toHaveCount(1);
	await expect(page.getByRole('button', { name: '新项目' })).toHaveText('');
	await expect(page.locator('[data-project-id="2"]')).toHaveClass(/pinned/);
	await expect(page.locator('.project-pin-status')).toHaveCount(0);
	await expect(page.locator('.project-copy small')).toHaveCount(0);
	await expect(page.locator('.view-head .view-count')).toHaveCount(0);
	const viewCount = page.locator('.view-count-dock');
	await expect(viewCount).toHaveText('2');
	await expect(viewCount).toHaveAttribute('aria-label', '2 张卡片');

	const projectBarBox = await projectBar.boundingBox();
	const cardViewBox = await page.locator('.card-view').boundingBox();
	const taskPanelBox = await page.locator('#task-panel').boundingBox();
	const viewCountBox = await viewCount.boundingBox();
	expect(Math.abs((projectBarBox?.width ?? 0) - (cardViewBox?.width ?? 999))).toBeLessThanOrEqual(1);
	expect((viewCountBox?.y ?? 0) + (viewCountBox?.height ?? 0)).toBeGreaterThan(720);
	expect((viewCountBox?.x ?? 0) + (viewCountBox?.width ?? 0)).toBeGreaterThan(1140);
	expect(await viewCount.evaluate((count) => getComputedStyle(count).backgroundColor)).toBe('rgba(0, 0, 0, 0)');
	expect(await viewCount.evaluate((count) => getComputedStyle(count).boxShadow)).toBe('none');
	expect((cardViewBox?.x ?? 0) + (cardViewBox?.width ?? 0)).toBeGreaterThan(
		taskPanelBox?.x ?? 1200
	);
	expect(taskPanelBox?.y ?? 0).toBeGreaterThanOrEqual(
		(projectBarBox?.y ?? 0) + (projectBarBox?.height ?? 0) + 8
	);
	const projectItem = page.locator('[data-project-id="1"]');
	const projectItemBox = await projectItem.boundingBox();
	expect(projectItemBox?.width ?? 999).toBeLessThanOrEqual(150);
	expect(projectItemBox?.height ?? 999).toBeGreaterThanOrEqual(40);
	expect(projectItemBox?.height ?? 999).toBeLessThanOrEqual(41);
	expect(
		await projectItem.evaluate((item) => Number.parseFloat(getComputedStyle(item).borderRadius))
	).toBeGreaterThanOrEqual(((projectItemBox?.height ?? 999) / 2) - 1);
	const projectGlyph = projectItem.locator('.project-glyph');
	const projectGlyphBox = await projectGlyph.boundingBox();
	expect(projectGlyphBox?.width ?? 999).toBeLessThanOrEqual(24);
	expect((await projectGlyph.locator('svg').boundingBox())?.width ?? 0).toBeGreaterThanOrEqual(16);
	const projectGlyphStyles = await projectGlyph.evaluate((glyph) => ({
		background: getComputedStyle(glyph).backgroundColor,
		shadow: getComputedStyle(glyph).boxShadow
	}));
	expect(projectGlyphStyles.background).toBe('rgba(0, 0, 0, 0)');
	expect(projectGlyphStyles.shadow).toBe('none');
	const projectMenuTrigger = projectItem.locator('.project-menu-trigger');
	expect((await projectMenuTrigger.boundingBox())?.width ?? 999).toBeLessThanOrEqual(24);
	expect((await projectMenuTrigger.locator('svg').boundingBox())?.width ?? 999).toBeLessThanOrEqual(12);
	expect(Number(await projectMenuTrigger.evaluate((trigger) => getComputedStyle(trigger).opacity))).toBeGreaterThan(0);
	const selectedStyles = await projectItem.evaluate((item) => {
		const originalColor = item.style.getPropertyValue('--project-color');
		const before = getComputedStyle(item);
		const initial = { background: before.backgroundColor, shadow: before.boxShadow };
		item.style.setProperty('--project-color', '#ff00ff');
		const after = getComputedStyle(item);
		const changed = { background: after.backgroundColor, shadow: after.boxShadow };
		item.style.setProperty('--project-color', originalColor);
		return { initial, changed };
	});
	expect(selectedStyles.changed.background).not.toBe(selectedStyles.initial.background);
	expect(selectedStyles.changed.shadow).toBe(selectedStyles.initial.shadow);

	await page.screenshot({ path: `${ARTIFACTS}/board-light.png` });
});

test('项目切换、置顶/收藏最终意图、全局收藏与窄窗', async ({ page }) => {
	await boot(page);

	const alphaItem = page.locator('[data-project-id="1"]');
	const betaItem = page.locator('[data-project-id="2"]');
	const alphaX = (await alphaItem.boundingBox())?.x ?? 0;
	const betaX = (await betaItem.boundingBox())?.x ?? 0;
	expect(betaX).toBeLessThan(alphaX); // Beta 初始置顶，稳定前置

	// 编辑态必须完整收在弹窗内；此前十个固定宽度色块撑破了 26rem 网格轨道
	let projectActions = await openProjectActions(page, alphaItem);
	await finishMotion(projectActions);
	await expect(projectActions.locator('.project-menu-item')).toHaveCount(3);
	expect((await projectActions.boundingBox())?.width ?? 999).toBeLessThanOrEqual(136);
	for (const action of await projectActions.locator('.project-menu-item').all()) {
		expect((await action.boundingBox())?.width ?? 999).toBeLessThanOrEqual(40);
		expect((await action.locator('.project-menu-icon').boundingBox())?.width ?? 999).toBeLessThanOrEqual(32);
		expect((await action.textContent())?.trim()).toBe('');
	}
	await page.screenshot({ path: `${ARTIFACTS}/project-actions.png` });
	await projectActions.getByRole('button', { name: '编辑项目' }).click();
	const editProject = page.getByRole('dialog', { name: '编辑项目' });
	await expect(editProject).toBeVisible();
	await finishMotion(editProject);
	expect(
		await editProject.evaluate((dialog) => dialog.scrollWidth - dialog.clientWidth)
	).toBeLessThanOrEqual(1);
	await page.screenshot({ path: `${ARTIFACTS}/project-dialog.png` });
	await page.keyboard.press('Escape');
	await expect(editProject).toBeHidden();

	projectActions = await openProjectActions(page, alphaItem);
	const alphaPin = projectActions.getByRole('button', { name: '置顶项目' });
	const projectMotionMark = await motionMark(page, 'project-item');
	const pinWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	const pinReflow = expectMotionSince(page, 'project-item', projectMotionMark, 'transform');
	await alphaPin.click();
	expect((await pinWrite).query).toContain('is_pinned');
	await pinReflow;
	await expect(alphaItem).toHaveClass(/pinned/);
	await expect(alphaItem.locator('.project-pin-status')).toHaveCount(0);
	await expect(alphaItem.getByRole('button', { name: /^更多项目操作：.*已置顶/ })).toBeVisible();

	// 同步双击合并为串行 false → true，最终状态写回数据库；重载后仍为 true
	projectActions = await openProjectActions(page, alphaItem);
	await finishMotion(projectActions);
	await page.screenshot({ path: `${ARTIFACTS}/project-actions-pinned.png` });
	const alphaUnpin = projectActions.getByRole('button', { name: '取消置顶项目' });
	const pinColors = await alphaUnpin.evaluate((button) => {
		const colorProbe = document.createElement('span');
		colorProbe.style.color = 'var(--color-star)';
		document.body.append(colorProbe);
		const colors = {
			action: getComputedStyle(button).color,
			star: getComputedStyle(colorProbe).color
		};
		colorProbe.remove();
		return colors;
	});
	expect(pinColors.action).toBe(pinColors.star);
	const doublePinWrites = nextMockEvents<SqlWrite>(page, 'cuepad:e2e-sql-write', 2);
	await alphaUnpin.evaluate((item: HTMLElement) => {
		item.click();
		item.click();
	});
	const pinValues = (await doublePinWrites).map((write) => write.values[0]);
	expect(pinValues).toEqual([0, 1]);
	await expect(alphaItem).toHaveClass(/pinned/);
	await expect(alphaItem.locator('.project-pin-status')).toHaveCount(0);
	await expect(alphaItem.getByRole('button', { name: /^更多项目操作：.*已置顶/ })).toBeVisible();
	await page.reload();
	await expect(page.getByRole('heading', { name: 'Alpha', exact: true })).toBeVisible();
	await expect(page.locator('[data-project-id="1"]')).toHaveClass(/pinned/);
	await expect(page.locator('[data-project-id="1"] .project-pin-status')).toHaveCount(0);
	await expect(page.locator('[data-project-id="1"]').getByRole('button', { name: /^更多项目操作：.*已置顶/ })).toBeVisible();
	expect((await page.locator('[data-project-id="1"]').boundingBox())?.x ?? 0).toBeLessThan(
		(await page.locator('[data-project-id="2"]').boundingBox())?.x ?? 0
	);

	// 同置顶分区内真实 pointer 拖拽：Beta → Alpha 前；切出分区再切回仍保留基础顺序
	const projectReorder = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await dragBefore(
		page,
		page.locator('[data-project-id="2"] .project-select'),
		page.locator('[data-project-id="1"]'),
		/drop-left/
	);
	const projectReorderWrite = await projectReorder;
	expect(projectReorderWrite.query).toContain('UPDATE projects SET sort_order');
	expect([projectReorderWrite.values[2], projectReorderWrite.values[5]]).toEqual([2, 1]);
	await expect(page.locator('[data-project-id]').first()).toHaveAttribute('data-project-id', '2');
	const betaItemAfterDrag = page.locator('[data-project-id="2"]');
	projectActions = await openProjectActions(page, betaItemAfterDrag);
	const betaUnpinWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await projectActions.getByRole('button', { name: '取消置顶项目' }).click();
	await betaUnpinWrite;
	projectActions = await openProjectActions(page, betaItemAfterDrag);
	const betaRepinWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await projectActions.getByRole('button', { name: '置顶项目' }).click();
	await betaRepinWrite;
	await expect(page.locator('[data-project-id]').first()).toHaveAttribute('data-project-id', '2');
	await page.reload();
	await expect(page.locator('[data-project-id]').first()).toHaveAttribute('data-project-id', '2');

	// 项目换页不应把新卡从缩放偏移位置拉回，卡片首次与最终布局需一致
	await page.locator('[data-project-id="2"] .project-select').click();
	await expect(page.getByRole('heading', { name: 'Beta', exact: true })).toBeVisible();
	await finishSubtreeMotion(page.locator('.card-view'));
	const cardMovement = cardMovementAfterInsert(page, '1');
	await page.locator('[data-project-id="1"] .project-select').click();
	await expect(page.getByRole('heading', { name: 'Alpha', exact: true })).toBeVisible();
	expect(Math.hypot(...Object.values(await cardMovement))).toBeLessThanOrEqual(0.5);

	// 命令面板项目命中与项目栏共用选择入口；选择经唯一 localStorage key 恢复
	await page.getByRole('button', { name: /搜索/ }).click();
	const projectPalette = page.getByRole('dialog', { name: '命令面板' });
	await projectPalette.getByRole('textbox', { name: '搜索' }).fill('Beta');
	await projectPalette.getByRole('button', { name: 'Beta', exact: true }).click();
	await expect(page.getByRole('heading', { name: 'Beta', exact: true })).toBeVisible();
	await expect(page.locator('.card h3', { hasText: 'Beta 提示词' })).toBeVisible();
	await expect(page.locator('.card h3', { hasText: 'Alpha 发布检查单' })).toBeHidden();
	expect(await page.evaluate(() => localStorage.getItem('cuepad:active-project'))).toBe('2');
	await page.reload();
	await expect(page.getByRole('heading', { name: 'Beta', exact: true })).toBeVisible();

	// 全局收藏跨项目展示，不提供拖拽 ghost；项目点击退出并保留统一选择入口
	await page.getByRole('button', { name: '全局收藏' }).click();
	await expect(page.getByRole('heading', { name: '全局收藏' })).toBeVisible();
	await expect(page.locator('.card h3', { hasText: 'Alpha 发布检查单' })).toBeVisible();
	await expect(page.locator('.card h3', { hasText: 'Beta 提示词' })).toBeHidden();
	await expect(page.getByRole('button', { name: '新建卡片' })).toHaveCount(0);
	await page.screenshot({ path: `${ARTIFACTS}/board-favorites.png` });

	await page.locator('[data-project-id="1"] .project-select').click();
	await expect(page.getByRole('heading', { name: 'Alpha', exact: true })).toBeVisible();
	const firstCard = page.locator('[data-card-id="1"]');
	const secondCard = page.locator('[data-card-id="2"]');

	// 命中区保持 40px，但视觉面只占 28px；先收藏第二张，再取消第一张，星标分区产生 FLIP 重排
	await secondCard.hover();
	for (const action of await secondCard.locator('.card-action').all()) {
		const actionBox = await action.boundingBox();
		expect(actionBox?.width ?? 0).toBeCloseTo(40, 3);
		expect(actionBox?.height ?? 0).toBeCloseTo(40, 3);
		expect((await action.locator('.card-action-icon').boundingBox())?.width ?? 999).toBeLessThanOrEqual(28);
		expect(await action.evaluate((button) => getComputedStyle(button).backgroundColor)).toBe('rgba(0, 0, 0, 0)');
	}
	const secondStar = secondCard.getByRole('button', { name: '收藏' });
	const starIconMark = await motionMark(page, 'fx-icon-on');
	await page.evaluate(() => {
		(window as unknown as { __E2E_HOLD_ENTITY_SELECT__: string }).__E2E_HOLD_ENTITY_SELECT__ = 'cards';
	});
	const selectHeld = nextMockEvent<string>(page, 'cuepad:e2e-select-held');
	const favoriteWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	const starIcon = expectMotionSince(page, 'fx-icon-on', starIconMark, 'opacity');
	await secondStar.click();
	expect((await favoriteWrite).query).toContain('is_favorite');
	expect(await selectHeld).toBe('cards');

	const actionWidth = await secondCard.locator('.card-actions').evaluate(
		(element) => getComputedStyle(element).width
	);
	const cardReorder = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await dragBefore(page, secondCard.locator('.card-hit'), firstCard);
	const cardReorderWrite = await cardReorder;
	expect(cardReorderWrite.query).toContain('UPDATE cards SET sort_order');
	expect([cardReorderWrite.values[2], cardReorderWrite.values[5]]).toEqual([2, 1]);
	await expect(page.locator('.grid > [data-card-id]').first()).toHaveAttribute('data-card-id', '2');
	await page.evaluate(() => {
		(window as unknown as { __E2E_RELEASE_ENTITY_SELECT__: (() => void) | null })
			.__E2E_RELEASE_ENTITY_SELECT__?.();
	});
	await settled(page);
	await starIcon;
	await expect(page.locator('.grid > [data-card-id]').first()).toHaveAttribute('data-card-id', '2');

	const cardMotionMark = await motionMark(page, 'cell');
	const starExitMark = await motionMark(page, 'fx-icon-on');
	const unfavoriteWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	const cardReflow = expectMotionSince(page, 'cell', cardMotionMark, 'transform');
	const starExit = expectMotionSince(page, 'fx-icon-on', starExitMark, 'opacity');
	await secondCard.getByRole('button', { name: '取消收藏' }).click();
	await unfavoriteWrite;
	await Promise.all([cardReflow, starExit]);
	await expect(page.locator('.grid > [data-card-id]').first()).toHaveAttribute('data-card-id', '1');
	await secondCard.hover();
	await settled(page);
	const refavoriteWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await secondCard.getByRole('button', { name: '收藏' }).click();
	await refavoriteWrite;
	await expect(page.locator('.grid > [data-card-id]').first()).toHaveAttribute('data-card-id', '2');
	expect(
		await secondCard.locator('.card-actions').evaluate((element) => getComputedStyle(element).width)
	).toBe(actionWidth);
	for (const action of await firstCard.locator('.card-action').all()) {
		expect(await action.evaluate((element) => getComputedStyle(element).transitionProperty)).not.toMatch(
			/width|margin/
		);
	}

	// 无效恢复值按“未归档有卡”回退，并把校验后的值写回同一个 key
	await page.evaluate(() => localStorage.setItem('cuepad:active-project', '999'));
	await page.reload();
	await expect(page.getByRole('heading', { name: '未归档' })).toBeVisible();
	await expect(page.getByText('收件箱里的灵感')).toBeVisible();
	expect(await page.evaluate(() => localStorage.getItem('cuepad:active-project'))).toBe('inbox');
	await finishSubtreeMotion(page.locator('.board'));

	await page.setViewportSize({ width: 420, height: 760 });
	const compactProjectBar = page.locator('.project-bar');
	expect(
		await compactProjectBar.evaluate((bar) => getComputedStyle(bar, '::-webkit-scrollbar').display)
	).toBe('none');
	await compactProjectBar.dispatchEvent('wheel', { deltaY: 120, bubbles: true, cancelable: true });
	expect(await compactProjectBar.evaluate((bar) => bar.scrollLeft)).toBeGreaterThan(0);

	await page.setViewportSize({ width: 720, height: 760 });
	await expect(page.locator('#task-panel')).toHaveCount(0);
	await page.locator('.project-bar').evaluate((bar) => (bar.scrollLeft = bar.scrollWidth));
	await settled(page);
	const newProjectBox = await page.getByRole('button', { name: '新项目' }).boundingBox();
	const lastProjectBox = await page.locator('[data-project-id="2"]').boundingBox();
	expect((newProjectBox?.x ?? 0) + (newProjectBox?.width ?? 0)).toBeLessThanOrEqual(720);
	expect((lastProjectBox?.x ?? 0) + (lastProjectBox?.width ?? 0)).toBeLessThanOrEqual(
		newProjectBox?.x ?? 720
	);
	await page.locator('.project-bar').evaluate((bar) => (bar.scrollLeft = 0));
	await settled(page);
	await page.screenshot({ path: `${ARTIFACTS}/board-narrow.png` });
});

test('悬浮任务：全局 CRUD、排序、完成反悔、项目关联与窄窗', async ({ page }) => {
	await boot(page);
	await finishSubtreeMotion(page.locator('#task-panel'));

	const taskPanel = page.locator('#task-panel');
	const activeTaskIds = () =>
		page.locator('[data-task-state="active"]').evaluateAll((rows) =>
			rows.map((row) => row.getAttribute('data-task-id'))
		);
	await expect(taskPanel).toBeVisible();
	expect(await taskPanel.evaluate((panel) => getComputedStyle(panel).backgroundColor)).toBe(
		'rgba(0, 0, 0, 0)'
	);
	const panelBox = await taskPanel.boundingBox();
	const rightmostCardBox = await page.locator('.cell').last().boundingBox();
	expect((rightmostCardBox?.x ?? 0) + (rightmostCardBox?.width ?? 0)).toBeLessThanOrEqual(
		panelBox?.x ?? 1200
	);
	await page.screenshot({ path: `${ARTIFACTS}/tasks-light.png` });

	// Pointer Capture 下不能依赖 elementFromPoint；两项须能向上换序再向下复原
	expect(await activeTaskIds()).toEqual(['1', '2']);
	await page.evaluate(() => {
		const globals = window as unknown as {
			__E2E_ELEMENT_FROM_POINT__: typeof document.elementFromPoint;
		};
		globals.__E2E_ELEMENT_FROM_POINT__ = document.elementFromPoint.bind(document);
		document.elementFromPoint = () => null;
	});
	const initialTopTask = page.locator('[data-task-id="1"]');
	const initialBottomTask = page.locator('[data-task-id="2"]');
	await moveTaskPointer(page, initialBottomTask.locator('.task-copy'), initialTopTask, 0.75);
	const neutralIndicator = page.locator('[data-task-drop-indicator]');
	await expect(neutralIndicator).toBeVisible();
	const initialTopBounds = await initialTopTask.boundingBox();
	const initialBottomBounds = await initialBottomTask.boundingBox();
	expect(await verticalCenter(neutralIndicator)).toBeGreaterThan(
		(initialTopBounds?.y ?? 0) + (initialTopBounds?.height ?? 0)
	);
	expect(await verticalCenter(neutralIndicator)).toBeLessThan(
		initialBottomBounds?.y ?? Number.POSITIVE_INFINITY
	);
	await page.mouse.up();
	const initialUpwardWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await moveTaskPointer(
		page,
		page.locator('[data-task-id="2"] .task-copy'),
		initialTopTask,
		0.15
	);
	await expect(neutralIndicator).toBeVisible();
	const upwardLineBounds = await neutralIndicator.boundingBox();
	const upwardTopBounds = await initialTopTask.boundingBox();
	const taskScrollBounds = await page.locator('.task-list-scroll').boundingBox();
	expect(await verticalCenter(neutralIndicator)).toBeLessThan(upwardTopBounds?.y ?? 0);
	expect(upwardLineBounds?.y ?? 0).toBeGreaterThanOrEqual(taskScrollBounds?.y ?? 0);
	await page.mouse.up();
	expect((await initialUpwardWrite).query).toContain('UPDATE tasks SET sort_order');
	expect(await activeTaskIds()).toEqual(['2', '1']);
	await page.evaluate(() => {
		const globals = window as unknown as {
			__E2E_ELEMENT_FROM_POINT__: typeof document.elementFromPoint;
		};
		document.elementFromPoint = globals.__E2E_ELEMENT_FROM_POINT__;
		delete (globals as Partial<typeof globals>).__E2E_ELEMENT_FROM_POINT__;
	});
	await finishSubtreeMotion(page.locator('.active-tasks'));
	const initialDownwardWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	const initialEndZone = page.locator('[data-task-drop-end]');
	await moveTaskPointer(
		page,
		page.locator('[data-task-id="2"] .task-copy'),
		initialEndZone,
		0.75
	);
	await expect(neutralIndicator).toBeVisible();
	const initialLastBounds = await page.locator('[data-task-id="1"]').boundingBox();
	expect(await verticalCenter(neutralIndicator)).toBeGreaterThan(
		(initialLastBounds?.y ?? 0) + (initialLastBounds?.height ?? 0)
	);
	await page.mouse.up();
	expect((await initialDownwardWrite).query).toContain('UPDATE tasks SET sort_order');
	expect(await activeTaskIds()).toEqual(['1', '2']);

	// 空白不创建；有效任务前插并产生自身 enter，不让父任务栈闪动
	await page.getByRole('button', { name: '新建任务' }).click();
	const creator = page.getByRole('textbox', { name: '任务内容' });
	await page.getByRole('button', { name: '添加任务' }).click();
	await expect(page.getByRole('alert')).toHaveText('任务内容不能为空');
	await creator.fill('确认发布文案');
	const createMotionMark = await motionMark(page, 'task-motion');
	const createMotion = expectMotionSince(page, 'task-motion', createMotionMark, 'transform');
	const createWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await page.getByRole('button', { name: '添加任务' }).click();
	expect((await createWrite).query).toContain('INSERT INTO tasks');
	await createMotion;
	const createdTask = page.locator('[data-task-id="4"][data-task-state="active"]');
	await expect(createdTask).toContainText('确认发布文案');
	expect((await activeTaskIds())[0]).toBe('4');

	// 行内空白提交保留编辑态；有效内容与项目分配分别持久化
	await createdTask.locator('.task-copy').click();
	const editor = createdTask.getByRole('textbox', { name: '编辑任务' });
	await editor.fill('   ');
	await editor.press('Enter');
	await expect(createdTask.getByRole('alert')).toHaveText('任务内容不能为空');
	await editor.fill('确认最终发布文案');
	const editWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await editor.press('Enter');
	expect((await editWrite).query).toContain('content = $1');
	await expect(createdTask).toContainText('确认最终发布文案');

	await createdTask.getByRole('button', { name: '未分配项目' }).click();
	const projectMenu = page.locator('[data-task-project-menu]');
	await expect(projectMenu).toBeVisible();
	const assignWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await projectMenu.getByRole('button', { name: 'Beta', exact: true }).click();
	expect((await assignWrite).query).toContain('project_id = $1');
	await expect(projectMenu).toBeHidden();
	await expect(createdTask.getByRole('button', { name: '项目：Beta' })).toBeVisible();

	// 切项目与全局收藏不改变任务集合或顺序
	const globalOrder = await activeTaskIds();
	await page.locator('[data-project-id="2"] .project-select').click();
	await expect(page.getByRole('heading', { name: 'Beta', exact: true })).toBeVisible();
	expect(await activeTaskIds()).toEqual(globalOrder);
	await page.getByRole('button', { name: '全局收藏' }).click();
	await expect(page.getByRole('heading', { name: '全局收藏' })).toBeVisible();
	expect(await activeTaskIds()).toEqual(globalOrder);
	await page.locator('[data-project-id="1"] .project-select').click();

	// 活动区纵向拖拽，完成项不进入 reorder ids
	const reorderMark = await motionMark(page, 'task-motion');
	const reorderMotion = expectMotionSince(page, 'task-motion', reorderMark, 'transform');
	const reorderWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await moveTaskPointer(
		page,
		page.locator('[data-task-id="2"] .task-copy'),
		page.locator('[data-task-id="4"]'),
		0.15
	);
	await page.mouse.up();
	const taskOrderWrite = await reorderWrite;
	expect(taskOrderWrite.query).toContain('UPDATE tasks SET sort_order');
	expect([taskOrderWrite.values[2], taskOrderWrite.values[5], taskOrderWrite.values[8]]).toEqual([
		2, 4, 1
	]);
	await reorderMotion;
	expect((await activeTaskIds())[0]).toBe('2');
	await finishSubtreeMotion(page.locator('.active-tasks'));

	// 真实失败路径：首项越过末项后必须落在其后，不能因残留 before 退回原位
	const downwardWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await moveTaskPointer(
		page,
		page.locator('[data-task-id="2"] .task-copy'),
		page.locator('[data-task-id="1"]'),
		0.85
	);
	const downwardIndicator = page.locator('[data-task-drop-indicator]');
	await expect(downwardIndicator).toBeVisible();
	const downwardLastBounds = await page.locator('[data-task-id="1"]').boundingBox();
	expect(await verticalCenter(downwardIndicator)).toBeGreaterThan(
		(downwardLastBounds?.y ?? 0) + (downwardLastBounds?.height ?? 0)
	);
	await page.mouse.up();
	expect((await downwardWrite).query).toContain('UPDATE tasks SET sort_order');
	expect(await activeTaskIds()).toEqual(['4', '1', '2']);
	await page.reload();
	await expect(page.getByRole('heading', { name: 'Alpha', exact: true })).toBeVisible();
	expect(await activeTaskIds()).toEqual(['4', '1', '2']);

	// 越过末项后释放仍属于活动区末尾落点
	const endZone = page.locator('[data-task-drop-end]');
	await expect(endZone).toBeVisible();
	const appendWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await moveTaskPointer(
		page,
		page.locator('[data-task-id="4"] .task-copy'),
		endZone,
		0.75
	);
	await expect(page.locator('[data-task-drop-indicator]')).toBeVisible();
	await page.mouse.up();
	expect((await appendWrite).query).toContain('UPDATE tasks SET sort_order');
	expect(await activeTaskIds()).toEqual(['1', '2', '4']);

	// 同步双切合并最终意图：完成 → 恢复串行落库，最终仍在活动区且重载保持
	const taskOne = page.locator('[data-task-id="1"][data-task-state="active"]');
	const doubleStateWrites = nextMockEvents<SqlWrite>(page, 'cuepad:e2e-sql-write', 2);
	await taskOne.getByRole('button', { name: /完成任务：检查明天演示环境/ }).evaluate(
		(button: HTMLButtonElement) => {
			button.click();
			button.click();
		}
	);
	const completionValues = (await doubleStateWrites).map((write) => write.values[0]);
	expect(typeof completionValues[0]).toBe('number');
	expect(completionValues[1]).toBeNull();
	await expect(taskOne).toBeVisible();
	await page.reload();
	await expect(page.locator('[data-task-id="1"][data-task-state="active"]')).toBeVisible();

	// 单次完成短退出到折叠区；展开后恢复到基础手动顺序
	const taskFour = page.locator('[data-task-id="4"][data-task-state="active"]');
	await finishMotion(taskFour.locator('..'));
	const completeMark = await motionMark(page, 'task-motion');
	const completeMotion = expectMotionSince(page, 'task-motion', completeMark, 'transform');
	const completeWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await taskFour.getByRole('button', { name: /完成任务：确认最终发布文案/ }).click();
	await completeWrite;
	await expect(taskFour).toBeHidden();
	await completeMotion;
	await page.getByRole('button', { name: /已完成/ }).click();
	const completedTask = page.locator('[data-task-id="4"][data-task-state="completed"]');
	await expect(completedTask).toBeVisible();
	const restoreWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await completedTask.getByRole('button', { name: /恢复任务：确认最终发布文案/ }).click();
	await restoreWrite;
	await expect(page.locator('[data-task-id="4"][data-task-state="active"]')).toBeVisible();
	expect((await activeTaskIds()).slice(0, 3)).toEqual(['1', '2', '4']);

	// 两击前不删除，第二击才 hard delete；任务不进入回收站
	const deleteTask = page.locator('[data-task-id="4"][data-task-state="active"]');
	await deleteTask.hover();
	const writesBeforeDelete = await page.evaluate(
		() => (window as unknown as { __E2E_SQL_WRITES__: unknown[] }).__E2E_SQL_WRITES__.length
	);
	await deleteTask.getByRole('button', { name: /永久删除任务：确认最终发布文案/ }).click();
	await expect(deleteTask.getByRole('button', { name: /再点一次永久删除任务/ })).toBeVisible();
	expect(
		await page.evaluate(
			() => (window as unknown as { __E2E_SQL_WRITES__: unknown[] }).__E2E_SQL_WRITES__.length
		)
	).toBe(writesBeforeDelete);
	const deleteMark = await motionMark(page, 'task-motion');
	const deleteMotion = expectMotionSince(page, 'task-motion', deleteMark, 'transform');
	const deleteWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await deleteTask.getByRole('button', { name: /再点一次永久删除任务/ }).click();
	expect((await deleteWrite).query).toContain('DELETE FROM tasks');
	await expect(deleteTask).toBeHidden();
	await deleteMotion;

	// 深色任务视觉资产
	await page.getByRole('button', { name: '设置' }).click();
	let settings = page.getByRole('dialog', { name: '设置' });
	await settings.getByRole('button', { name: '深色' }).click();
	await page.keyboard.press('Escape');
	await expect(settings).toBeHidden();
	await page.screenshot({ path: `${ARTIFACTS}/tasks-dark.png` });

	// 项目软删保留 task FK 并明示已回收；恢复后自动复原；hard delete 后变未分配
	const betaItem = page.locator('[data-project-id="2"]');
	let projectActions = await openProjectActions(page, betaItem);
	const softDeleteWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await projectActions.getByRole('button', { name: '移入回收站' }).click();
	await softDeleteWrite;
	const betaTask = page.locator('[data-task-id="2"]');
	await expect(betaTask.getByRole('button', { name: /项目已回收：Beta/ })).toBeVisible();
	await expect(betaTask.getByText('已回收')).toBeVisible();

	await page.getByRole('button', { name: '设置' }).click();
	settings = page.getByRole('dialog', { name: '设置' });
	await settings.getByRole('button', { name: '打开回收站' }).click();
	let trash = page.getByRole('dialog', { name: '回收站' });
	const trashedBeta = trash.locator('.trash-row', { hasText: 'Beta' });
	const restoreProjectWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await trashedBeta.getByRole('button', { name: '恢复项目' }).click();
	await restoreProjectWrite;
	await page.keyboard.press('Escape');
	await expect(trash).toBeHidden();
	await expect(betaTask.getByRole('button', { name: '项目：Beta' })).toBeVisible();

	projectActions = await openProjectActions(page, page.locator('[data-project-id="2"]'));
	const secondSoftDelete = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await projectActions.getByRole('button', { name: '移入回收站' }).click();
	await secondSoftDelete;
	await page.getByRole('button', { name: '设置' }).click();
	settings = page.getByRole('dialog', { name: '设置' });
	await settings.getByRole('button', { name: '打开回收站' }).click();
	trash = page.getByRole('dialog', { name: '回收站' });
	const destroyBeta = trash.locator('.trash-row', { hasText: 'Beta' });
	await destroyBeta.getByRole('button', { name: '永久删除项目' }).click();
	const destroyProjectWrite = nextMockEvent<SqlWrite>(page, 'cuepad:e2e-sql-write');
	await destroyBeta.getByRole('button', { name: '再点一次永久删除' }).click();
	await destroyProjectWrite;
	await page.keyboard.press('Escape');
	await expect(trash).toBeHidden();
	await expect(betaTask.getByRole('button', { name: '未分配项目' })).toBeVisible();

	// 720px 只常驻入口；展开后工作区让位，sticky 新建和卡片操作不被覆盖
	await page.getByRole('button', { name: '设置' }).click();
	settings = page.getByRole('dialog', { name: '设置' });
	await settings.getByRole('button', { name: '浅色' }).click();
	await page.keyboard.press('Escape');
	await page.setViewportSize({ width: 720, height: 520 });
	const narrowTrigger = page.locator('[data-task-narrow-trigger]');
	await expect(narrowTrigger).toBeVisible();
	await expect(narrowTrigger).toBeInViewport();
	await expect(page.locator('#task-panel')).toHaveCount(0);
	await page.setViewportSize({ width: 720, height: 760 });
	await expect(narrowTrigger).toBeInViewport();
	await page.screenshot({ path: `${ARTIFACTS}/tasks-narrow.png` });
	await narrowTrigger.click();
	await expect(page.locator('#task-panel')).toBeVisible();
	await page.locator('.project-bar').evaluate((bar) => (bar.scrollLeft = bar.scrollWidth));
	await settled(page);
	const narrowPanelBox = await page.locator('#task-panel').boundingBox();
	const newProjectBox = await page.getByRole('button', { name: '新项目' }).boundingBox();
	expect((newProjectBox?.x ?? 0) + (newProjectBox?.width ?? 0)).toBeLessThanOrEqual(
		narrowPanelBox?.x ?? 720
	);
	for (const actions of await page.locator('.card-actions').all()) {
		const box = await actions.boundingBox();
		expect((box?.x ?? 0) + (box?.width ?? 0)).toBeLessThanOrEqual(narrowPanelBox?.x ?? 720);
	}

	// 沉浸编辑打开时任务栈从 DOM 与焦点顺序中移除
	await narrowTrigger.click();
	await page.locator('.project-bar').evaluate((bar) => (bar.scrollLeft = 0));
	await page.locator('.card h3', { hasText: 'Alpha 发布检查单' }).click();
	await expect(page.locator('.focus')).toBeVisible();
	await expect(page.locator('.task-stack')).toHaveCount(0);
});

test('设置弹层：回收站入口、深色主题切换、进场含位移动画', async ({ page }) => {
	await boot(page);

	await page.evaluate(() => window.dispatchEvent(new Event('cuepad:e2e-open-settings')));
	const settings = page.getByRole('dialog', { name: '设置' });
	await expect(settings).toBeVisible();
	await expect(settings.getByText('回收站')).toBeVisible();
	await expect(settings.getByText('/tmp/cuepad-e2e/cuepad.db')).toBeVisible();
	await expect(settings.getByText('CuePad v0.0.0-e2e')).toBeVisible();
	await settings.getByRole('button', { name: '重新录制全局快捷键' }).click();
	await settings.locator('[data-shortcut-recorder]').dispatchEvent('keydown', {
		key: 'j',
		code: 'KeyJ',
		ctrlKey: true,
		altKey: true,
		bubbles: true
	});
	await expect(settings.getByRole('button', { name: '重新录制全局快捷键' })).toBeVisible();
	// 进场：DIALOG_FLY 经 motionFly 产生 transform 关键帧
	await expectMotionSince(page, 'settings-card', 0, 'transform');

	await settings.getByRole('button', { name: '深色' }).click();
	await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
	await page.screenshot({ path: `${ARTIFACTS}/settings-dark.png` });

	// 设置内打开回收站：设置关闭、回收站打开（弹层互斥不叠加）
	await finishMotion(settings);
	const settingsMark = await motionMark(page, 'settings-card');
	const settingsOutro = expectMotionSince(page, 'settings-card', settingsMark, 'transform');
	await settings.getByRole('button', { name: '打开回收站' }).click();
	const trash = page.getByRole('dialog', { name: '回收站' });
	await expect(trash.getByText('回收站是空的')).toBeVisible();
	await expect(settings).toBeHidden();
	// 设置退场（增量）+ 回收站进场都有过渡
	await settingsOutro;
	await expectMotionSince(page, 'trash-card', 0, 'transform');
	await page.screenshot({ path: `${ARTIFACTS}/trash-dark.png` });

	// 退场：逐个具名断言隐藏（泛化 dialog locator 在 outro 重叠窗口内会命中多元素触发 strict violation）
	await finishMotion(trash);
	const trashMark = await motionMark(page, 'trash-card');
	const trashOutro = expectMotionSince(page, 'trash-card', trashMark, 'transform');
	await page.keyboard.press('Escape');
	await expect(trash).toBeHidden();
	await trashOutro;
	await expect(settings).toBeHidden();
	await page.screenshot({ path: `${ARTIFACTS}/board-dark.png` });
});

test('项目弹层与命令面板进出场', async ({ page }) => {
	await boot(page);

	await page.getByRole('button', { name: '新项目' }).click();
	const project = page.getByRole('dialog', { name: '新建项目' });
	await expect(project).toBeVisible();
	await expectMotionSince(page, 'dialog-card', 0, 'transform');
	await finishMotion(project);
	const projectMark = await motionMark(page, 'dialog-card');
	const projectOutro = expectMotionSince(page, 'dialog-card', projectMark, 'transform');
	await page.keyboard.press('Escape');
	await expect(project).toBeHidden();
	await projectOutro;

	await page.getByRole('button', { name: /搜索/ }).click();
	const palette = page.getByRole('dialog', { name: '命令面板' });
	await expect(palette.getByText('新建卡片')).toBeVisible();
	await expect(palette.getByText('打开回收站')).toBeVisible();
	await expectMotionSince(page, 'palette', 0, 'transform');
	await page.screenshot({ path: `${ARTIFACTS}/palette.png` });
	await palette.getByRole('textbox', { name: '搜索' }).fill('Alpha');
	await expect(page.getByRole('button', { name: '投送 Alpha 发布检查单 到 Terminal' })).toBeVisible();

	// 无变量卡片从 action 直接投送，不打开变量表单；该 action 同时触发命令面板退场
	await palette.getByRole('textbox', { name: '搜索' }).fill('Beta');
	const dispatchBeta = page.getByRole('button', { name: '投送 Beta 提示词 到 Terminal' });
	await expect(dispatchBeta).toBeVisible();
	await finishMotion(palette);
	const paletteMark = await motionMark(page, 'palette');
	const paletteOutro = expectMotionSince(page, 'palette', paletteMark, 'transform');
	const betaDispatch = nextMockEvent<DispatchResult>(page, 'cuepad:e2e-dispatch-complete');
	await dispatchBeta.click();
	await expect(palette).toBeHidden();
	await expect(page.getByRole('dialog', { name: '填写变量' })).toBeHidden();
	const betaResult = await betaDispatch;
	expect(betaResult.text).toBe('给模型的系统提示词草稿');
	expect(betaResult.bundleId).toBeNull();
	// 命令面板退场（POP_SCALE 经 motionScale，增量）
	await paletteOutro;

	// 卡片命中先切换统一项目视图再打开编辑器；未保存草稿随即经命令面板投送
	// 必须发送当前草稿而非数据库旧值（自动保存 debounce 窗口内 DB 落后）
	await page.getByRole('button', { name: /搜索/ }).click();
	await palette.getByRole('textbox', { name: '搜索' }).fill('Beta');
	await palette.locator('.card-result', { hasText: 'Beta 提示词' }).locator('.palette-item').click();
	const editorContent = page.locator('.cm-content');
	await expect(editorContent).toBeVisible();
	await editorContent.click();
	await page.keyboard.type('未保存草稿：');
	// 沉浸覆盖层下用 DOM 事件打开面板（顶栏被遮挡，不等自动保存）
	await page.evaluate(() => {
		const buttons = Array.from(document.querySelectorAll<HTMLButtonElement>('button'));
		buttons.find((button) => button.textContent?.includes('搜索'))?.click();
	});
	await expect(palette).toBeVisible();
	await palette.getByRole('textbox', { name: '搜索' }).fill('Beta');
	const draftDispatch = nextMockEvent<DispatchResult>(page, 'cuepad:e2e-dispatch-complete');
	await page.getByRole('button', { name: '投送 Beta 提示词 到 Terminal' }).click();
	expect((await draftDispatch).text).toContain('未保存草稿：');
});

test('沉浸编辑：变量填充、复制与投送', async ({ page }) => {
	await boot(page);

	await page.getByText('Alpha 发布检查单').click();
	const focus = page.locator('.focus');
	await expect(focus).toBeVisible();
	// 覆盖层进场：overlayEnter 全程不透明缩放（transform）
	await expectMotionSince(page, 'focus-overlay', 0, 'transform');

	// 块系统视觉：分隔线编号 pill + {{变量}} 高亮；历史角色标记（---ask--- 等）宽容解析为普通分隔线
	await expect(page.locator('.cm-cue-divider-label').filter({ hasText: '2' })).toBeVisible();
	await expect(page.locator('.cm-cue-var')).toHaveText('{{产品名}}');

	// 分隔线已控件化：源标记永不渲染；块首 Backspace 整条删除合并块，撤销可恢复
	await expect(page.locator('.cm-content')).not.toContainText('---ask---');
	await expect(page.locator('.cm-cue-divider')).toHaveCount(2);
	await page.locator('.cm-line', { hasText: '性能、隐私、价格。' }).click();
	await page.keyboard.press('Home');
	await page.keyboard.press('Backspace');
	await expect(page.locator('.cm-cue-divider')).toHaveCount(1);
	await page.keyboard.press('Meta+z');
	await expect(page.locator('.cm-cue-divider')).toHaveCount(2);

	// 默认上一个应用；可从运行中应用固定目标，选择立即持久化并同步按钮标签
	await expect(page.getByRole('button', { name: '投送全文到 Terminal' })).toBeVisible();
	await page.getByRole('button', { name: '选择投送目标' }).click();
	const targetMenu = page.getByRole('menu');
	await expect(targetMenu.getByRole('menuitem', { name: /上一个应用.*Terminal/ })).toBeVisible();
	await targetMenu.getByRole('menuitem', { name: 'Zed', exact: true }).click();
	await expect(page.getByRole('button', { name: '投送全文到 Zed' })).toBeVisible();
	await page.getByRole('button', { name: '选择投送目标' }).click();
	await targetMenu.getByRole('menuitem', { name: /上一个应用.*Terminal/ }).click();
	await expect(page.getByRole('button', { name: '投送全文到 Terminal' })).toBeVisible();
	await page.getByRole('button', { name: '选择投送目标' }).click();
	await targetMenu.getByRole('menuitem', { name: 'Zed', exact: true }).click();
	await expect(page.getByRole('button', { name: '投送全文到 Zed' })).toBeVisible();
	expect(await page.evaluate(() => localStorage.getItem('cuepad:dispatch-target'))).toContain(
		'dev.zed.Zed'
	);

	// 含变量的复制先填写；确认后才写剪贴板并显示成功 Toast
	await page.getByRole('button', { name: '复制全文' }).click();
	const variableDialog = page.getByRole('dialog', { name: '填写变量' });
	await expect(variableDialog).toBeVisible();
	const variableInput = variableDialog.getByRole('textbox', { name: '产品名' });
	await variableInput.fill('CuePad');
	await expect(variableInput).toHaveValue('CuePad');
	const copiedPrompt = nextMockEvent<string>(page, 'cuepad:e2e-clipboard-complete');
	await variableDialog.getByRole('button', { name: '复制', exact: true }).click();
	await expect(variableDialog).toBeHidden();
	const toast = page.getByRole('status');
	await expect(toast.getByText('已复制全文')).toBeVisible();
	expect(await copiedPrompt).toContain('介绍 CuePad 的核心能力');
	// Toast 进场（motionFly）；自动隐藏前先完成 intro、标记并订阅 outro
	await expectMotionSince(page, 'toast', 0, 'transform');
	await finishMotion(toast);
	const toastMark = await motionMark(page, 'toast');
	const toastOutro = expectMotionSince(page, 'toast', toastMark, 'opacity');
	await page.screenshot({ path: `${ARTIFACTS}/focus-editor.png` });

	// 同卡再次投送时预填上次值；确认后成品文本和固定 bundle id 走 dispatch_text
	await page.getByRole('button', { name: '投送全文到 Zed' }).click();
	await expect(variableDialog.getByRole('textbox', { name: '产品名' })).toHaveValue('CuePad');
	const dispatchedPrompt = nextMockEvent<DispatchResult>(page, 'cuepad:e2e-dispatch-complete');
	await variableDialog.getByRole('button', { name: '投送', exact: true }).click();
	await expect(variableDialog).toBeHidden();
	const dispatchedResult = await dispatchedPrompt;
	expect(dispatchedResult.text).toContain('介绍 CuePad 的核心能力');
	expect(dispatchedResult.bundleId).toBe('dev.zed.Zed');
	expect(dispatchedResult.submit).toBe(false);

	// 投送后自动发送：菜单顶部开关（位置稳定不随应用列表漂移），持久化并随后续投送透传
	await page.getByRole('button', { name: '选择投送目标' }).click();
	const submitToggle = page.getByRole('menuitem', { name: /自动发送/ });
	await expect(page.getByRole('menu').getByRole('menuitem').first()).toContainText('自动发送');
	await submitToggle.click();
	await page.keyboard.press('Escape');
	expect(await page.evaluate(() => localStorage.getItem('cuepad:dispatch-submit'))).toBe('1');

	// 无变量卡直达路径的并发防重：同步双击模拟快速连击，in-flight 锁下 dispatch_text 恰好一次
	await page.keyboard.press('Escape');
	await expect(focus).toBeHidden();
	await page.getByText('快速草稿：明天的演示流程').click();
	await expect(focus).toBeVisible();
	const directDispatch = nextMockEvent<DispatchResult>(page, 'cuepad:e2e-dispatch-complete');
	await page
		.getByRole('button', { name: '投送全文到 Zed' })
		.evaluate((button: HTMLButtonElement) => {
			button.click();
			button.click();
		});
	const directResult = await directDispatch;
	expect(directResult.text).toContain('快速草稿：明天的演示流程');
	expect(directResult.calls).toBe(2);
	expect(directResult.submit).toBe(true);

	// 剪贴板互斥：投送在途时复制被忽略，不会覆盖目标即将粘贴的内容
	await page.evaluate(() => {
		const globals = window as unknown as {
			__E2E_DISPATCH_DELAY__: number;
			__E2E_CLIPBOARD__: string;
		};
		globals.__E2E_DISPATCH_DELAY__ = 200;
		globals.__E2E_CLIPBOARD__ = 'sentinel';
	});
	const delayedDispatch = nextMockEvent<DispatchResult>(page, 'cuepad:e2e-dispatch-complete');
	await page.getByRole('button', { name: '投送全文到 Zed' }).click();
	await page.getByRole('button', { name: '复制全文' }).click();
	expect((await delayedDispatch).calls).toBe(3);
	expect(
		await page.evaluate(
			() => (window as unknown as { __E2E_CLIPBOARD__: string }).__E2E_CLIPBOARD__
		)
	).toBe('sentinel');
	await page.evaluate(() => {
		(window as unknown as { __E2E_DISPATCH_DELAY__: number }).__E2E_DISPATCH_DELAY__ = 0;
	});

	// 表单留空的变量保留占位符：双变量填一留一，复制结果不丢 {{乙}}
	await page.locator('.cm-content').click();
	await page.keyboard.type('{{甲}}与{{乙}}：');
	await page.getByRole('button', { name: '复制全文' }).click();
	const partialDialog = page.getByRole('dialog', { name: '填写变量' });
	await expect(partialDialog).toBeVisible();
	const partialInput = partialDialog.getByRole('textbox', { name: '甲' });
	await partialInput.fill('已填');
	await expect(partialInput).toHaveValue('已填');
	await expect(partialDialog.getByRole('textbox', { name: '乙' })).toHaveValue('');
	const partialCopy = nextMockEvent<string>(page, 'cuepad:e2e-clipboard-complete');
	await partialDialog.getByRole('button', { name: '复制', exact: true }).click();
	await expect(partialDialog).toBeHidden();
	expect(await partialCopy).toContain('已填与{{乙}}：');

	await page.keyboard.press('Escape');
	await expect(focus).toBeHidden();
	await page.getByText('Alpha 发布检查单').click();
	await expect(focus).toBeVisible();

	// 编号是编辑态草稿：切换后不等写库立即复制，必须用新编号（同步连击模拟）
	await page.getByRole('button', { name: '更多操作' }).click();
	await expect(page.getByRole('group', { name: '编号风格' })).toBeVisible();
	await page.evaluate(() => {
		const options = Array.from(document.querySelectorAll<HTMLButtonElement>('.numbering-option'));
		options.find((option) => option.textContent?.trim() === '无')?.click();
		document.querySelector<HTMLButtonElement>('button[aria-label="复制全文"]')?.click();
	});
	const numberingDialog = page.getByRole('dialog', { name: '填写变量' });
	await expect(numberingDialog).toBeVisible();
	const numberingCopy = nextMockEvent<string>(page, 'cuepad:e2e-clipboard-complete');
	await numberingDialog.getByRole('button', { name: '复制', exact: true }).click();
	await expect(numberingDialog).toBeHidden();
	const renumbered = await numberingCopy;
	expect(renumbered).toContain('---\n\n用户最关心');
	expect(renumbered).not.toContain('## 1');
	await page.keyboard.press('Escape');

	// 固定应用退出后保留选择并标记未运行；投送明确报错，不静默回退到 Terminal
	await page.evaluate(() => {
		const globals = window as unknown as {
			__E2E_DISPATCH_TARGETS__: { bundleId: string; name: string }[];
		};
		globals.__E2E_DISPATCH_TARGETS__ = globals.__E2E_DISPATCH_TARGETS__.filter(
			(target) => target.bundleId !== 'dev.zed.Zed'
		);
	});
	await page.getByRole('button', { name: '选择投送目标' }).click();
	await expect(targetMenu.getByRole('menuitem', { name: /Zed.*未运行/ })).toBeDisabled();
	await page.keyboard.press('Escape');
	await page.getByRole('button', { name: '投送全文到 Zed' }).click();
	await variableDialog.getByRole('button', { name: '投送', exact: true }).click();
	await expect(toast.getByText('找不到投送目标')).toBeVisible();

	// Accessibility 错误不能静默：保留表单预填，并显示系统设置路径
	await page.evaluate(() => {
		(window as unknown as { __E2E_DISPATCH_ERROR__: string }).__E2E_DISPATCH_ERROR__ =
			'ACCESSIBILITY_PERMISSION_REQUIRED';
	});
	await page.getByRole('button', { name: '投送全文到 Zed' }).click();
	await variableDialog.getByRole('button', { name: '投送', exact: true }).click();
	await expect(toast.getByText('需要辅助功能权限')).toBeVisible();
	await expect(toast.getByText(/系统设置 → 隐私与安全性 → 辅助功能/)).toBeVisible();

	// 覆盖层退场：intro 完成后预先订阅 out:motionScale（增量）
	const overlay = page.locator('.focus-overlay');
	await finishMotion(overlay);
	const overlayMark = await motionMark(page, 'focus-overlay');
	const overlayOutro = expectMotionSince(page, 'focus-overlay', overlayMark, 'transform');
	await page.keyboard.press('Escape');
	await expect(focus).toBeHidden();
	await overlayOutro;

	// Toast 自动隐藏（2.2s）退场：out:fade 含 opacity
	await expect(toast).toBeHidden({ timeout: 5_000 });
	await toastOutro;

	// WebView 全量重载后仍读取固定目标，等价覆盖 CuePad 重启时的前端持久化入口
	await page.reload();
	await expect(page.getByRole('heading', { name: 'Alpha', exact: true })).toBeVisible({
		timeout: 20_000
	});
	await page.getByText('Alpha 发布检查单').click();
	await expect(page.getByRole('button', { name: '投送全文到 Zed' })).toBeVisible();
});

test('减弱动态效果：装饰动画停用，过渡降级为纯淡入淡出', async ({ page }) => {
	await page.emulateMedia({ reducedMotion: 'reduce' });
	await boot(page, { welcomed: false });

	// 装饰性 CSS 动画（吉祥物悬浮）被门控；popRise 减动路径：欢迎卡进场只有 opacity
	const welcome = page.getByRole('dialog', { name: '欢迎' });
	await expect(welcome).toBeVisible();
	await expectMotionSince(page, 'welcome-card', 0, 'opacity');
	for (const record of await motionLog(page, 'welcome-card')) {
		expect(record.props).not.toContain('transform');
	}
	const mascot = page.locator('.mascot').first();
	await expect(mascot).toBeVisible();
	expect(
		await mascot.evaluate((node) => getComputedStyle(node).animationName)
	).toBe('none');

	await page.getByRole('button', { name: '开始使用' }).click();
	await expect(welcome).toBeHidden();

	// 任务完成与项目菜单各自降级为 opacity；任务父容器不产生整体动画
	const taskMotionMark = await motionMark(page, 'task-motion');
	const reducedTaskMotion = expectMotionSince(page, 'task-motion', taskMotionMark, 'opacity');
	await page
		.locator('[data-task-id="1"]')
		.getByRole('button', { name: /完成任务：检查明天演示环境/ })
		.click();
	await expect(page.locator('[data-task-id="1"][data-task-state="active"]')).toBeHidden();
	await reducedTaskMotion;
	for (const record of (await motionLog(page, 'task-motion')).slice(taskMotionMark)) {
		expect(record.props).not.toContain('transform');
	}
	const menuMotionMark = await motionMark(page, 'project-menu');
	const reducedMenuMotion = expectMotionSince(page, 'project-menu', menuMotionMark, 'opacity');
	await page.locator('[data-task-id="2"]').getByRole('button', { name: '项目：Beta' }).click();
	await reducedMenuMotion;
	for (const record of (await motionLog(page, 'project-menu')).slice(menuMotionMark)) {
		expect(record.props).not.toContain('transform');
	}
	await page.keyboard.press('Escape');
	await expect(page.locator('[data-task-project-menu]')).toBeHidden();

	// JS 减动路径：motionFly/motionScale 降级为 FADE_ONLY——弹层进场只有 opacity，无 transform
	await page.getByRole('button', { name: '设置' }).click();
	const settings = page.getByRole('dialog', { name: '设置' });
	await expect(settings.getByText('回收站')).toBeVisible();
	await expectMotionSince(page, 'settings-card', 0, 'opacity');
	for (const record of await motionLog(page, 'settings-card')) {
		expect(record.props).not.toContain('transform');
	}
	// 切显式浅色：后续 CSS 交互断言覆盖「data-theme 显式设置 + 减动」分支
	//（token 定义在 :root[data-theme='light'] 特异度 0-1-1，减动覆盖选择器必须不低于它）
	await settings.getByRole('button', { name: '浅色' }).click();
	await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
	await page.keyboard.press('Escape');
	await expect(settings).toBeHidden();

	// motionScale 减动路径：命令面板进退场均降级为纯 opacity
	await page.getByRole('button', { name: /搜索/ }).click();
	const palette = page.getByRole('dialog', { name: '命令面板' });
	await expect(palette).toBeVisible();
	await expectMotionSince(page, 'palette', 0, 'opacity');
	for (const record of await motionLog(page, 'palette')) {
		expect(record.props).not.toContain('transform');
	}
	await finishMotion(palette);
	const paletteMark = await motionMark(page, 'palette');
	const paletteOutro = expectMotionSince(page, 'palette', paletteMark, 'opacity');
	await page.keyboard.press('Escape');
	await expect(palette).toBeHidden();
	await paletteOutro;
	for (const record of (await motionLog(page, 'palette')).slice(paletteMark)) {
		expect(record.props).not.toContain('transform');
	}

	// overlayEnter 减动路径：duration 0，覆盖层无 transform 进场动画
	await page.getByText('Alpha 发布检查单').click();
	const overlay = page.locator('.focus-overlay');
	await expect(overlay).toBeVisible();
	for (const record of await motionLog(page, 'focus-overlay')) {
		expect(record.props).not.toContain('transform');
	}
	await page.keyboard.press('Escape');
	await expect(overlay).toBeHidden();

	// CSS 交互减动（显式浅色主题下）：装饰变换幅度 token 归 1，hover/press 不产生缩放/位移终态
	const NO_SCALE = ['none', 'matrix(1, 0, 0, 1, 0, 0)'];
	await page.locator('[data-project-id="2"] .project-select').click();
	const card = page.locator('.card').filter({ hasText: 'Beta 提示词' });
	// 全局 reset 机制：任一 CSS transition 消费点都被压至 0.01ms，不逐元素重复断言
	const trashButton = card.getByRole('button', { name: '移入回收站' });
	expect(
		await trashButton.evaluate((el) =>
			getComputedStyle(el)
				.transitionDuration.split(', ')
				.every((duration) => Number.parseFloat(duration) === 0.00001)
		)
	).toBe(true);
	await card.hover();
	await settled(page);
	expect(['none', '0px', '0px 0px']).toContain(
		await card.evaluate((el) => getComputedStyle(el).translate)
	);
	// ghost 卡加号：rotate+scale 组合变换被组件内门控归零（transform: none）
	const ghost = page.getByRole('button', { name: '新建卡片' }).first();
	await ghost.hover();
	await settled(page);
	expect(NO_SCALE).toContain(
		await ghost.locator('svg').evaluate((el) => getComputedStyle(el).transform)
	);
	await page.getByRole('button', { name: '新项目' }).click();
	const swatch = page.locator('.swatch').first();
	await swatch.hover();
	await settled(page);
	expect(NO_SCALE).toContain(await swatch.evaluate((el) => getComputedStyle(el).transform));
	const submit = page.getByRole('button', { name: '创建项目' });
	await submit.hover();
	await page.mouse.down();
	await settled(page);
	expect(NO_SCALE).toContain(await submit.evaluate((el) => getComputedStyle(el).transform));
	// 移出后再抬起：只采样 :active 态，不真的提交表单
	await page.mouse.move(5, 5);
	await page.mouse.up();
	await page.keyboard.press('Escape');
	await expect(page.getByRole('dialog', { name: '新建项目' })).toBeHidden();

	// motionFlip 减动路径：切全局收藏触发卡片切换，FLIP duration 0 → 无新增 transform 动画
	const before = (await motionLog(page, 'cell')).length;
	await page.getByRole('button', { name: '全局收藏' }).click();
	await expect(page.getByRole('heading', { name: '全局收藏' })).toBeVisible();
	const after = await motionLog(page, 'cell');
	for (const record of after.slice(before)) {
		expect(record.props).not.toContain('transform');
	}
});
