import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { cp, mkdir } from 'node:fs/promises';
import { createServer } from 'node:net';

function freePort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const server = createServer();
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => {
			const address = server.address();
			if (!address || typeof address === 'string') {
				server.close();
				reject(new Error('无法分配 E2E 端口'));
				return;
			}
			server.close((error) => (error ? reject(error) : resolve(address.port)));
		});
	});
}

const port = process.env.CUEPAD_E2E_PORT ?? String(await freePort());
const runId = `${Date.now()}-${process.pid}-${randomUUID().slice(0, 8)}`;
const artifacts = process.env.CUEPAD_E2E_DIR ?? `/tmp/cuepad-e2e/${runId}`;
await mkdir(artifacts, { recursive: true });
// 只读复制默认 dep cache 作种子；Vite 后续仅写 run 私有副本，兼顾并发隔离与启动速度
await cp('node_modules/.vite', `${artifacts}/vite-cache`, { recursive: true }).catch((error) => {
	if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
});
const playwright = spawn('bunx', ['playwright', 'test', ...process.argv.slice(2)], {
	stdio: 'inherit',
	env: {
		...process.env,
		CUEPAD_E2E_PORT: port,
		CUEPAD_E2E_DIR: artifacts
	}
});

process.exitCode = await new Promise<number>((resolve, reject) => {
	playwright.once('error', reject);
	playwright.once('exit', (code) => resolve(code ?? 1));
});
