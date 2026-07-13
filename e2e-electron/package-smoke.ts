import assert from 'node:assert/strict';
import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { watch, type FSWatcher } from 'node:fs';
import { access, mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import packageJson from '../package.json' with { type: 'json' };

const APP_PATH = path.resolve('release/mac-arm64/CuePad.app');
const EXECUTABLE_PATH = path.join(APP_PATH, 'Contents', 'MacOS', 'CuePad');
const RESOURCES_PATH = path.join(APP_PATH, 'Contents', 'Resources');
const START_TIMEOUT_MS = 30_000;
const execFileAsync = promisify(execFile);

type DevToolsEndpoint = { port: number; websocketPath: string };
type PendingRequest = { resolve(value: unknown): void; reject(error: Error): void };
type TargetInfo = { targetId: string; type: string; url: string };
type PackageState = {
	appVersion: string;
	databasePath: string;
	migrations: { version: number }[];
	targets: { bundleId: string | null; name: string }[];
	title: string;
	url: string;
};

class CdpClient {
	private nextId = 1;
	private readonly eventWaiters = new Map<string, Set<PendingRequest>>();
	private readonly pending = new Map<number, PendingRequest>();

	private constructor(private readonly socket: WebSocket) {
		socket.addEventListener('message', (event) => this.onMessage(String(event.data)));
		socket.addEventListener('close', () => this.rejectPending(new Error('CDP WebSocket 已关闭')));
	}

	static async connect(url: string) {
		const socket = new WebSocket(url);
		await new Promise<void>((resolve, reject) => {
			const timeout = setTimeout(() => reject(new Error('连接打包应用 CDP 超时')), START_TIMEOUT_MS);
			socket.addEventListener('open', () => {
				clearTimeout(timeout);
				resolve();
			}, { once: true });
			socket.addEventListener('error', () => {
				clearTimeout(timeout);
				reject(new Error('连接打包应用 CDP 失败'));
			}, { once: true });
		});
		return new CdpClient(socket);
	}

	request<T>(method: string, params: Record<string, unknown> = {}, sessionId?: string): Promise<T> {
		const id = this.nextId++;
		return new Promise<T>((resolve, reject) => {
			this.pending.set(id, { resolve: (value) => resolve(value as T), reject });
			this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
		});
	}

	waitForEvent<T>(method: string, sessionId: string): Promise<T> {
		const key = `${sessionId}:${method}`;
		return new Promise<T>((resolve, reject) => {
			const timeout = setTimeout(() => {
				this.eventWaiters.get(key)?.delete(waiter);
				reject(new Error(`等待 CDP 事件超时：${method}`));
			}, START_TIMEOUT_MS);
			const waiter: PendingRequest = {
				resolve: (value) => {
					clearTimeout(timeout);
					resolve(value as T);
				},
				reject
			};
			const waiters = this.eventWaiters.get(key) ?? new Set<PendingRequest>();
			waiters.add(waiter);
			this.eventWaiters.set(key, waiters);
		});
	}

	async evaluate<T>(sessionId: string, expression: string): Promise<T> {
		const response = await this.request<{
			exceptionDetails?: { exception?: { description?: string }; text: string };
			result: { value: T };
		}>('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
		if (response.exceptionDetails) {
			throw new Error(response.exceptionDetails.exception?.description ?? response.exceptionDetails.text);
		}
		return response.result.value;
	}

	close() {
		this.socket.close();
	}

	private onMessage(message: string) {
		const response = JSON.parse(message) as {
			id?: number;
			method?: string;
			params?: unknown;
			result?: unknown;
			error?: { message: string };
			sessionId?: string;
		};
		if (response.method && response.sessionId) {
			const key = `${response.sessionId}:${response.method}`;
			const waiters = this.eventWaiters.get(key);
			if (waiters) {
				this.eventWaiters.delete(key);
				for (const waiter of waiters) waiter.resolve(response.params);
			}
		}
		if (response.id === undefined) return;
		const pending = this.pending.get(response.id);
		if (!pending) return;
		this.pending.delete(response.id);
		if (response.error) pending.reject(new Error(response.error.message));
		else pending.resolve(response.result);
	}

	private rejectPending(error: Error) {
		for (const request of this.pending.values()) request.reject(error);
		this.pending.clear();
		for (const waiters of this.eventWaiters.values()) {
			for (const waiter of waiters) waiter.reject(error);
		}
		this.eventWaiters.clear();
	}
}

async function processTreeRss(rootPid: number) {
	const { stdout } = await execFileAsync('/bin/ps', ['-axo', 'pid=,ppid=,rss=']);
	const processes = stdout.trim().split('\n').map((line) => {
		const [pid, parentPid, rss] = line.trim().split(/\s+/).map(Number);
		return { pid, parentPid, rss };
	});
	const included = new Set([rootPid]);
	let added = true;
	while (added) {
		added = false;
		for (const process of processes) {
			if (included.has(process.pid) || !included.has(process.parentPid)) continue;
			included.add(process.pid);
			added = true;
		}
	}
	return {
		main: processes.find((process) => process.pid === rootPid)?.rss ?? 0,
		total: processes
			.filter((process) => included.has(process.pid))
			.reduce((total, process) => total + process.rss, 0)
	};
}

function waitForDevTools(child: ChildProcessWithoutNullStreams, userDataPath: string) {
	const portFile = path.join(userDataPath, 'DevToolsActivePort');
	return new Promise<DevToolsEndpoint>((resolve, reject) => {
		let settled = false;
		function onExit(code: number | null) {
			finish(new Error(`打包应用提前退出：${code}`));
		}
		function finish(result: DevToolsEndpoint | Error) {
			if (settled) return;
			settled = true;
			clearTimeout(timeout);
			watcher.close();
			child.off('exit', onExit);
			if (result instanceof Error) reject(result);
			else resolve(result);
		}
		async function readEndpoint() {
			try {
				const [portText, websocketPath] = (await readFile(portFile, 'utf8')).trim().split('\n');
				const port = Number.parseInt(portText, 10);
				if (Number.isInteger(port) && port > 0 && websocketPath) finish({ port, websocketPath });
			} catch (error) {
				if ((error as NodeJS.ErrnoException).code !== 'ENOENT') finish(error as Error);
			}
		}
		const watcher: FSWatcher = watch(userDataPath, (_event, filename) => {
			if (filename === 'DevToolsActivePort') void readEndpoint();
		});
		child.once('exit', onExit);
		const timeout = setTimeout(
			() => finish(new Error('等待打包应用 DevTools 端口超时')),
			START_TIMEOUT_MS
		);
		void readEndpoint();
	});
}

const userDataPath = await mkdtemp(path.join(tmpdir(), 'cuepad-packaged-e2e-'));
const startedAt = performance.now();
const child = spawn(EXECUTABLE_PATH, ['--remote-debugging-port=0', `--user-data-dir=${userDataPath}`], {
	env: { ...process.env, CUEPAD_TEST: '1' },
	stdio: ['ignore', 'pipe', 'pipe']
});
const exited = new Promise<number | null>((resolve) => child.once('exit', resolve));
let stderr = '';
child.stderr.on('data', (chunk: Buffer) => (stderr += chunk.toString()));
let cdp: CdpClient | undefined;
try {
	const endpoint = await waitForDevTools(child, userDataPath);
	cdp = await CdpClient.connect(`ws://127.0.0.1:${endpoint.port}${endpoint.websocketPath}`);
	const { targetInfos } = await cdp.request<{ targetInfos: TargetInfo[] }>('Target.getTargets');
	const target = targetInfos.find((candidate) =>
		candidate.type === 'page' && candidate.url.startsWith('cuepad://')
	);
	assert.ok(target, '未找到 cuepad:// renderer target');
	const { sessionId } = await cdp.request<{ sessionId: string }>(
		'Target.attachToTarget',
		{ targetId: target.targetId, flatten: true }
	);
	const loaded = cdp.waitForEvent('Page.loadEventFired', sessionId);
	await cdp.request('Page.enable', {}, sessionId);
	await loaded;
	const state = await cdp.evaluate<PackageState>(sessionId, `new Promise((resolve, reject) => {
		const timeout = setTimeout(() => reject(new Error('等待打包 renderer 就绪超时')), ${START_TIMEOUT_MS});
		const observer = new MutationObserver(check);
		async function check() {
			const ready = document.querySelector('.hero-start, .board, .hero-error');
			if (!ready) return;
			clearTimeout(timeout);
			observer.disconnect();
			try {
				const error = document.querySelector('.hero-error');
				if (error) throw new Error(error.textContent || '打包 renderer 加载失败');
				resolve({
					appVersion: await window.cuepad.app.version(),
					databasePath: await window.cuepad.app.databasePath(),
					migrations: await window.cuepad.sql.select('SELECT version FROM schema_migrations ORDER BY version'),
					targets: await window.cuepad.dispatch.targets(),
					title: document.title,
					url: location.href
				});
			} catch (error) {
				reject(error);
			}
		}
		observer.observe(document.body, { childList: true, subtree: true });
		void check();
	})`);
	assert.equal(state.title, 'CuePad');
	assert.equal(state.appVersion, packageJson.version);
	assert.match(state.url, /^cuepad:\/\/app\//);
	assert.deepEqual(state.migrations, [1, 2, 3, 4, 5].map((version) => ({ version })));
	assert.ok(state.targets.some((targetApp) => targetApp.bundleId === 'com.apple.finder'));
	assert.equal(state.databasePath, path.join(await realpath(userDataPath), 'cuepad.db'));
	await Promise.all([
		access(state.databasePath),
		access(path.join(RESOURCES_PATH, 'cuepad-dispatch')),
		access(path.join(RESOURCES_PATH, 'assets', 'trayTemplate.png')),
		access(path.join(RESOURCES_PATH, 'assets', 'trayTemplate@2x.png'))
	]);
	const startupMs = performance.now() - startedAt;
	const rss = await processTreeRss(child.pid!);
	console.log(
		`packaged Electron smoke passed (${state.targets.length} dispatch targets, `
		+ `startup ${(startupMs / 1_000).toFixed(3)}s, RSS main ${rss.main} KiB / tree ${rss.total} KiB)`
	);
} catch (error) {
	if (stderr.trim()) console.error(stderr.trim());
	throw error;
} finally {
	cdp?.close();
	if (child.exitCode === null && child.signalCode === null) child.kill();
	await exited;
	await rm(userDataPath, { recursive: true, force: true });
}
