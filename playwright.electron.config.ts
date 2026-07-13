import { defineConfig } from '@playwright/test';

const port = process.env.CUEPAD_ELECTRON_PORT;
if (!port) throw new Error('请通过 `bun run test:electron` 启动 Electron 验收');
const startUrl = `http://127.0.0.1:${port}`;

export default defineConfig({
	testDir: 'e2e-electron',
	testMatch: '**/*.e2e.ts',
	outputDir: `/tmp/cuepad-electron-e2e/${process.pid}`,
	fullyParallel: false,
	workers: 1,
	timeout: 30_000,
	webServer: {
		command: `bunx vite dev --host 127.0.0.1 --port ${port} --strictPort`,
		url: startUrl,
		reuseExistingServer: false,
		timeout: 120_000
	}
});
