import { browser, expect } from '@wdio/globals';

const TARGET_KEY = 'cuepad:dispatch-target';
const TARGET_EVENT = 'cuepad:dispatch-target';
const TEST_TARGET = JSON.stringify({ bundleId: 'com.cuepad.wdio.missing', name: 'WDIO 权限目标' });

function writeTarget(key: string, value: string | null, event: string) {
	if (value === null) localStorage.removeItem(key);
	else localStorage.setItem(key, value);
	window.dispatchEvent(new Event(event));
}

let previousTarget: string | null = null;

describe('真实 Tauri 权限链路', () => {
	before(async () => {
		previousTarget = await browser.execute((key) => localStorage.getItem(key), TARGET_KEY);
		await browser.execute(writeTarget, TARGET_KEY, TEST_TARGET, TARGET_EVENT);
	});

	after(async () => {
		await browser.execute(writeTarget, TARGET_KEY, previousTarget, TARGET_EVENT);
	});

	it('未授权时显示系统设置引导，不进入目标解析或静默成功', async () => {
		// 隔离数据目录首轮为空库（.hero-start 建卡），后续轮次直接开卡
		const opened = await browser.execute(() => {
			const entry = document.querySelector<HTMLButtonElement>('.hero-start, .card-hit');
			entry?.click();
			return Boolean(entry);
		});
		expect(opened).toBe(true);

		// 隐藏窗口中原生 element click 会挂起，全部交互经 DOM 事件完成；
		// MutationObserver 订阅按钮出现与 Toast 出现，不轮询。
		const message = await browser.executeAsync<string>((done) => {
			let dispatched = false;
			const advance = () => {
				const text = document.querySelector<HTMLElement>('.toast')?.innerText;
				if (text) {
					observer.disconnect();
					done(text);
					return;
				}
				if (dispatched) return;
				const dispatch = document.querySelector<HTMLButtonElement>(
					'button[aria-label="投送全文到 WDIO 权限目标"]'
				);
				if (!dispatch || dispatch.disabled) return;
				dispatched = true;
				dispatch.click();
			};
			const observer = new MutationObserver(advance);
			observer.observe(document.body, {
				attributes: true,
				attributeFilter: ['aria-label', 'disabled'],
				childList: true,
				subtree: true
			});
			advance();
		});

		expect(message).toContain('需要辅助功能权限');
		expect(message).toContain('系统设置 → 隐私与安全性 → 辅助功能');
	});
});
