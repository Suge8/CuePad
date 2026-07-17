// 段1：CDP screencast 直录 CuePad renderer（不受桌面 Space/遮挡影响）
// 前置：CuePad 演示实例运行中（9444）且窗口可见、位于卡片墙
// 产物：/tmp/cuepad-promo/frames/*.jpg + concat.txt → ui.mp4 由 make-gif.sh 生成
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { chromium } from '@playwright/test';

const FRAMES = '/tmp/cuepad-promo/frames';
rmSync(FRAMES, { recursive: true, force: true });
mkdirSync(FRAMES, { recursive: true });

const browser = await chromium.connectOverCDP('http://127.0.0.1:9444');
const page = browser.contexts()[0].pages()[0];
const session = await browser.contexts()[0].newCDPSession(page);

const timestamps = [];
let index = 0;
session.on('Page.screencastFrame', (frame) => {
	writeFileSync(`${FRAMES}/f${String(index).padStart(4, '0')}.jpg`, Buffer.from(frame.data, 'base64'));
	timestamps.push(frame.metadata.timestamp);
	index++;
	session.send('Page.screencastFrameAck', { sessionId: frame.sessionId }).catch(() => {});
});

// 演示动作：卡片墙静置 → hover+打开「代码评审」→ 阅读 → hover+一键投送
await session.send('Page.startScreencast', { format: 'jpeg', quality: 85 });
await page.waitForTimeout(1600);
const card = page.getByText('代码评审', { exact: true }).first();
await card.hover();
await page.waitForTimeout(500);
await card.click();
await page.waitForTimeout(2400);
const dispatchButton = page.getByRole('button', { name: /投送全文/ });
await dispatchButton.hover();
await page.waitForTimeout(600);
await dispatchButton.click(); // 真实投送：写剪贴板 → 隐藏窗口 → 激活终端 → Cmd+V
await page.waitForTimeout(1200);
await session.send('Page.stopScreencast');

// concat 清单（按帧真实时间戳）
const lines = [];
for (let i = 0; i < index; i++) {
	lines.push(`file 'f${String(i).padStart(4, '0')}.jpg'`);
	const duration = i + 1 < index ? timestamps[i + 1] - timestamps[i] : 1.5; // 尾帧停留
	lines.push(`duration ${duration.toFixed(4)}`);
}
writeFileSync(`${FRAMES}/concat.txt`, lines.join('\n') + '\n');
console.log(`frames: ${index}`);
await browser.close();
