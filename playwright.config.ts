import { defineConfig } from '@playwright/test';

/**
 * 无头视觉验收（e2e/*.e2e.ts）：WebKit 引擎与 Tauri 的 WKWebView 同族。
 * macOS 上 tauri-driver 不可用，视觉面用 vite dev + IPC mock 无头验证，
 * 托盘/全局热键/真 SQL 等壳能力仍需真机人工核查。
 *
 * e2e/run.ts 为每次调用分配空闲端口与独立产物目录；webServer 由 playwright
 * 独享管理（自启自收，不复用外部服务）。
 */
const PORT = process.env.CUEPAD_E2E_PORT;
const ARTIFACTS = process.env.CUEPAD_E2E_DIR;
if (!PORT || !ARTIFACTS) {
	throw new Error('请通过 `bun run test:e2e` 启动无头验收');
}

export default defineConfig({
	testDir: 'e2e',
	testMatch: '**/*.e2e.ts',
	// 产物在项目目录外：写入项目目录会被 vite watch 触发 full-reload 打断测试
	outputDir: `${ARTIFACTS}/test-output`,
	fullyParallel: false,
	use: {
		baseURL: `http://127.0.0.1:${PORT}`,
		viewport: { width: 1200, height: 760 }
	},
	projects: [{ name: 'webkit', use: { browserName: 'webkit' } }],
	webServer: {
		command: `bunx vite dev --host 127.0.0.1 --port ${PORT} --strictPort`,
		url: `http://127.0.0.1:${PORT}`,
		reuseExistingServer: false,
		// 默认 cache 不存在时需冷预构建；并发低性能环境给足外部服务启动时间
		timeout: 120_000
	}
});
