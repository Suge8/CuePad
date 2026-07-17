// 宣传截图场景驱动：把运行中的 CuePad（--remote-debugging-port=9444）置于目标 UI 状态
// 用法: node design/promo/shots/scene.mjs <welcome-close|board|editor|variables|search|esc> [参数]
import { chromium } from '@playwright/test';

const action = process.argv[2];
const browser = await chromium.connectOverCDP('http://127.0.0.1:9444');
const page = browser.contexts()[0].pages()[0];
const pause = (ms) => page.waitForTimeout(ms);

// 悬浮任务展开时会遮挡右侧卡片，点卡片前先收起
async function collapseTasks() {
	if (await page.getByText('回归卡片拖拽 e2e').isVisible().catch(() => false)) {
		await page.getByText('任务', { exact: true }).first().click();
		await pause(500);
	}
}

switch (action) {
	case 'welcome-close':
		await page.getByRole('button', { name: '开始使用' }).click();
		await pause(600);
		break;
	case 'board':
		await page.keyboard.press('Escape');
		await pause(600);
		break;
	case 'project': // 切换到项目栏指定项目
		await page.getByRole('navigation', { name: '项目' }).getByText(process.argv[3] ?? 'CuePad').click();
		await pause(600);
		break;
	case 'editor': // 打开指定标题卡片的沉浸编辑
		await collapseTasks();
		await page.getByText(process.argv[3] ?? '代码评审', { exact: true }).first().click();
		await pause(800);
		break;
	case 'variables': // 沉浸编辑内复制含变量卡片 → 变量填写弹窗（带真实感输入）
		await collapseTasks();
		await page.getByText(process.argv[3] ?? '重构模块', { exact: true }).first().click();
		await pause(800);
		await page.getByRole('button', { name: '复制全文' }).click();
		await pause(600);
		await page.getByLabel('模块路径').fill('src/lib/workspace/store.svelte.ts');
		await page.getByLabel('目标形态').fill('按职责拆分的多个子模块');
		await pause(400);
		break;
	case 'search':
		await page.keyboard.press('Meta+f');
		await pause(400);
		if (process.argv[3]) {
			await page.keyboard.type(process.argv[3], { delay: 60 });
			await pause(500);
		}
		break;
	case 'tasks': // 切换悬浮任务展开/收起
		await page.getByText('任务', { exact: true }).first().click();
		await pause(600);
		break;
	case 'theme': { // 切换主题：设置页 → 点主题按钮 → 关设置
		await page.getByRole('button', { name: '设置' }).click();
		await pause(500);
		await page.getByRole('group', { name: '主题' }).getByText(process.argv[3] ?? '深色').click();
		await pause(500);
		await page.keyboard.press('Escape');
		await pause(500);
		break;
	}
	case 'neutral': // 收起任务 + 鼠标移到空白处消除 hover 残留
		await collapseTasks();
		await page.mouse.move(600, 700);
		await pause(400);
		break;
	case 'esc':
		await page.keyboard.press('Escape');
		await pause(400);
		break;
	default:
		throw new Error(`未知场景: ${action}`);
}
await browser.close();
