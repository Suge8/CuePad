import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { cp, mkdir, readdir, rm, stat } from 'node:fs/promises';
import { createServer } from 'node:net';
import path from 'node:path';

const ARTIFACTS_ROOT = '/tmp/cuepad-e2e';
const RUN_DIRECTORY = /^\d+-\d+-[a-f0-9]{8}$/;
const RETENTION_MS = 7 * 24 * 60 * 60 * 1_000;

async function removeExpiredRuns() {
	const cutoff = Date.now() - RETENTION_MS;
	const entries = await readdir(ARTIFACTS_ROOT, { withFileTypes: true }).catch((error) => {
		if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
		throw error;
	});
	await Promise.all(entries
		.filter((entry) => entry.isDirectory() && RUN_DIRECTORY.test(entry.name))
		.map(async (entry) => {
			const runPath = path.join(ARTIFACTS_ROOT, entry.name);
			if ((await stat(runPath)).mtimeMs < cutoff) {
				await rm(runPath, { recursive: true, force: true });
			}
		}));
}

async function retainFailureArtifacts(directory: string) {
	const entries = await readdir(directory, { withFileTypes: true });
	await Promise.all(entries.map(async (entry) => {
		const entryPath = path.join(directory, entry.name);
		if (entry.isDirectory()) {
			await retainFailureArtifacts(entryPath);
			if ((await readdir(entryPath)).length === 0) await rm(entryPath, { recursive: true });
			return;
		}
		if (!entry.isFile() || !/\.(png|zip)$/.test(entry.name)) await rm(entryPath, { force: true });
	}));
}

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

await removeExpiredRuns();
const port = process.env.CUEPAD_E2E_PORT ?? String(await freePort());
const runId = `${Date.now()}-${process.pid}-${randomUUID().slice(0, 8)}`;
const ownsArtifacts = process.env.CUEPAD_E2E_DIR === undefined;
const artifacts = process.env.CUEPAD_E2E_DIR ?? path.join(ARTIFACTS_ROOT, runId);
await mkdir(artifacts, { recursive: true });
// 只读复制默认 dep cache 作种子；Vite 后续仅写 run 私有副本，兼顾并发隔离与启动速度
await cp('node_modules/.vite', `${artifacts}/vite-cache`, { recursive: true }).catch((error) => {
	if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
});
const isMacOS = process.platform === 'darwin';
if (isMacOS) spawn('/usr/bin/caffeinate', ['-u', '-t', '3'], { stdio: 'ignore' }).unref();
const playwrightCommand = isMacOS ? '/usr/bin/caffeinate' : 'bunx';
const playwrightArgs = isMacOS
	? ['-d', '--', 'bunx', 'playwright', 'test', ...process.argv.slice(2)]
	: ['playwright', 'test', ...process.argv.slice(2)];
const playwright = spawn(playwrightCommand, playwrightArgs, {
	stdio: 'inherit',
	env: {
		...process.env,
		CUEPAD_E2E_PORT: port,
		CUEPAD_E2E_DIR: artifacts
	}
});

const exitCode = await new Promise<number>((resolve, reject) => {
	playwright.once('error', reject);
	playwright.once('exit', (code) => resolve(code ?? 1));
});
if (ownsArtifacts) {
	if (exitCode === 0) await rm(artifacts, { recursive: true, force: true });
	else await retainFailureArtifacts(artifacts);
}
process.exitCode = exitCode;
