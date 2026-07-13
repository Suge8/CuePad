import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import path from 'node:path';
import type { DispatchApp } from './shared/bridge-types';

type SidecarResponse = {
	id: number;
	ok: boolean;
	data?: unknown;
	error?: string;
};

type PendingRequest = {
	resolve(value: unknown): void;
	reject(error: Error): void;
};

type SidecarOptions = {
	executablePath: string;
	arguments: string[];
};

type CreateSidecarOptions = {
	appPath: string;
	isPackaged: boolean;
	resourcesPath: string;
	hostPid: number;
	bundleId: string;
};

const CLOSE_TIMEOUT_MS = 1_000;

export class DispatchSidecar {
	private child: ChildProcessWithoutNullStreams | null = null;
	private closePromise: Promise<void> | null = null;
	private nextId = 1;
	private pending = new Map<number, PendingRequest>();
	private queue: Promise<void> = Promise.resolve();
	private startPromise: Promise<void> | null = null;
	private stdoutBuffer = '';

	constructor(private readonly options: SidecarOptions) {}

	start(): Promise<void> {
		return this.ensureStarted();
	}

	target(): Promise<DispatchApp | null> {
		return this.enqueue(() => this.request<DispatchApp | null>('target'));
	}

	targets(): Promise<DispatchApp[]> {
		return this.enqueue(() => this.request<DispatchApp[]>('targets'));
	}

	dispatch(bundleId: string | null, prepare: () => void | Promise<void>): Promise<void> {
		return this.enqueue(async () => {
			await this.request<DispatchApp>('target', { bundleId, prepare: true });
			await prepare();
			await this.request('dispatch', { bundleId });
		});
	}

	close(): Promise<void> {
		this.closePromise ??= this.closeChild();
		return this.closePromise;
	}

	private enqueue<T>(operation: () => Promise<T>): Promise<T> {
		const result = this.queue.then(operation, operation);
		this.queue = result.then(() => undefined, () => undefined);
		return result;
	}

	private async request<T>(cmd: string, fields: Record<string, unknown> = {}): Promise<T> {
		await this.ensureStarted();
		const child = this.child;
		if (!child?.stdin.writable) throw new Error('DISPATCH_SIDECAR_UNAVAILABLE');
		const id = this.nextId++;
		return new Promise<T>((resolve, reject) => {
			this.pending.set(id, {
				resolve: (value) => resolve(value as T),
				reject
			});
			child.stdin.write(`${JSON.stringify({ id, cmd, ...fields })}\n`, (error) => {
				if (!error) return;
				this.pending.delete(id);
				reject(new Error(`DISPATCH_SIDECAR_WRITE_FAILED:${error.message}`));
			});
		});
	}

	private ensureStarted(): Promise<void> {
		if (this.closePromise) return Promise.reject(new Error('DISPATCH_SIDECAR_CLOSED'));
		if (this.child && this.child.exitCode === null && this.child.signalCode === null) {
			return Promise.resolve();
		}
		this.startPromise ??= this.spawnChild().finally(() => {
			this.startPromise = null;
		});
		return this.startPromise;
	}

	private spawnChild(): Promise<void> {
		return new Promise((resolve, reject) => {
			const child = spawn(this.options.executablePath, this.options.arguments, {
				stdio: ['pipe', 'pipe', 'pipe']
			});
			this.child = child;
			this.stdoutBuffer = '';
			let spawned = false;
			child.once('spawn', () => {
				spawned = true;
				resolve();
			});
			child.once('error', (error) => {
				if (spawned) return;
				if (this.child === child) this.child = null;
				reject(new Error(`DISPATCH_SIDECAR_UNAVAILABLE:${error.message}`));
			});
			child.stdout.on('data', (chunk: Buffer) => this.readResponses(chunk));
			child.stderr.on('data', (chunk: Buffer) => {
				const message = chunk.toString().trim();
				if (message) console.error(`cuepad-dispatch: ${message}`);
			});
			child.once('exit', (code, signal) => this.handleExit(child, code, signal));
		});
	}

	private readResponses(chunk: Buffer) {
		this.stdoutBuffer += chunk.toString();
		let newline = this.stdoutBuffer.indexOf('\n');
		while (newline >= 0) {
			const line = this.stdoutBuffer.slice(0, newline);
			this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
			if (line) this.handleResponse(line);
			newline = this.stdoutBuffer.indexOf('\n');
		}
	}

	private handleResponse(line: string) {
		let response: SidecarResponse;
		try {
			response = JSON.parse(line) as SidecarResponse;
		} catch {
			this.failProtocol(`invalid JSON: ${line}`);
			return;
		}
		if (typeof response.id !== 'number' || typeof response.ok !== 'boolean') {
			this.failProtocol(`invalid response: ${line}`);
			return;
		}
		const pending = this.pending.get(response.id);
		if (!pending) {
			console.error(`cuepad-dispatch: unexpected response id ${response.id}`);
			return;
		}
		this.pending.delete(response.id);
		if (response.ok) pending.resolve(response.data);
		else pending.reject(new Error(response.error ?? 'DISPATCH_SIDECAR_ERROR'));
	}

	private failProtocol(detail: string) {
		const error = new Error(`DISPATCH_SIDECAR_PROTOCOL_ERROR:${detail}`);
		this.rejectPending(error);
		this.child?.kill();
	}

	private handleExit(
		child: ChildProcessWithoutNullStreams,
		code: number | null,
		signal: NodeJS.Signals | null
	) {
		if (this.child !== child) return;
		this.child = null;
		const reason = code === null ? signal : `code ${code}`;
		this.rejectPending(new Error(`DISPATCH_SIDECAR_EXITED:${reason ?? 'unknown'}`));
		if (!this.closePromise) console.error(`cuepad-dispatch exited: ${reason ?? 'unknown'}`);
	}

	private rejectPending(error: Error) {
		for (const request of this.pending.values()) request.reject(error);
		this.pending.clear();
	}

	private async closeChild(): Promise<void> {
		try {
			await this.startPromise;
		} catch {
			return;
		}
		const child = this.child;
		if (!child || child.exitCode !== null || child.signalCode !== null) return;
		await new Promise<void>((resolve) => {
			const timeout = setTimeout(() => child.kill(), CLOSE_TIMEOUT_MS);
			child.once('exit', () => {
				clearTimeout(timeout);
				resolve();
			});
			child.stdin.end();
		});
	}
}

export function createDispatchSidecar(options: CreateSidecarOptions): DispatchSidecar {
	const executablePath = process.env.CUEPAD_DISPATCH_SIDECAR_PATH
		?? (options.isPackaged
			? path.join(options.resourcesPath, 'cuepad-dispatch')
			: path.join(options.appPath, 'native', 'dispatch', 'target', 'release', 'cuepad-dispatch'));
	return new DispatchSidecar({
		executablePath,
		arguments: [
			'--exclude-pid',
			String(options.hostPid),
			'--exclude-bundle-id',
			options.bundleId
		]
	});
}
