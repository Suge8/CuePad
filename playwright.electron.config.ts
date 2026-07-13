import { defineConfig } from '@playwright/test';

const port = process.env.CUEPAD_ELECTRON_PORT;
if (!port) throw new Error('请通过 `bun run test:electron` 启动 Electron 验收');
const startUrl = `http://127.0.0.1:${port}`;
const outputDir = `/tmp/cuepad-electron-e2e/${port}`;

export default defineConfig({
	testDir: 'e2e-electron',
	testMatch: '**/*.e2e.ts',
	outputDir,
	fullyParallel: false,
	workers: 1,
	timeout: 30_000,
	webServer: {
		command: `CUEPAD_ELECTRON=1 CUEPAD_E2E_DIR=${outputDir} bunx vite dev --host 127.0.0.1 --port ${port} --strictPort`,
		url: startUrl,
		reuseExistingServer: false,
		timeout: 120_000
	}
});
