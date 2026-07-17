// 合成出图：headless Chromium 按精确画布截图
// 用法: node design/promo/compose/compose.mjs <html文件[?query]> <宽> <高> <输出png>
//       宽/高传 auto 时按 body 实际尺寸截图（frame.html 用）
import path from 'node:path';
import { chromium } from '@playwright/test';

const [htmlFile, width, height, output] = process.argv.slice(2);
const auto = width === 'auto';
const [filePart, query] = htmlFile.split('?');
const browser = await chromium.launch();
const page = await browser.newPage({
	viewport: auto ? { width: 2400, height: 1800 } : { width: Number(width), height: Number(height) },
	deviceScaleFactor: 1
});
await page.goto(`file://${path.resolve(filePart)}${query ? `?${query}` : ''}`);
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(300); // 大图解码
if (auto) await page.locator('body').screenshot({ path: output });
else await page.screenshot({ path: output });
await browser.close();
console.log(output);
