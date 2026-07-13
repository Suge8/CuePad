import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { strict as assert } from 'node:assert';

const directory = path.dirname(fileURLToPath(import.meta.url));
const executablePath = path.join(directory, 'target', 'release', 'cuepad-dispatch');
const child = spawn(executablePath, [
	'--exclude-pid',
	String(process.pid),
	'--exclude-bundle-id',
	'com.sugeh.cuepad'
], { stdio: ['pipe', 'pipe', 'pipe'] });
const pending = new Map<number, (response: unknown) => void>();
let nextId = 1;
let output = '';
let stderr = '';

child.stdout.on('data', (chunk: Buffer) => {
	output += chunk.toString();
	let newline = output.indexOf('\n');
	while (newline >= 0) {
		const line = output.slice(0, newline);
		output = output.slice(newline + 1);
		const response = JSON.parse(line) as { id: number };
		pending.get(response.id)?.(response);
		pending.delete(response.id);
		newline = output.indexOf('\n');
	}
});
child.stderr.on('data', (chunk: Buffer) => {
	stderr += chunk.toString();
});

function request(cmd: string) {
	const id = nextId++;
	return withTimeout(new Promise<unknown>((resolve, reject) => {
		pending.set(id, resolve);
		child.stdin.write(`${JSON.stringify({ id, cmd })}\n`, (error) => {
			if (!error) return;
			pending.delete(id);
			reject(error);
		});
	}), `request ${cmd}`);
}

function withTimeout<T>(promise: Promise<T>, operation: string): Promise<T> {
	return new Promise((resolve, reject) => {
		const timeout = setTimeout(() => reject(new Error(`${operation} timed out`)), 5_000);
		promise.then(
			(value) => {
				clearTimeout(timeout);
				resolve(value);
			},
			(error) => {
				clearTimeout(timeout);
				reject(error);
			}
		);
	});
}

try {
	const targets = await request('targets') as {
		id: number;
		ok: boolean;
		data: { bundleId: string | null; name: string }[];
	};
	assert.equal(targets.ok, true);
	assert(targets.data.some((target) => target.bundleId === 'com.apple.finder'));

	const unknown = await request('unknown') as { id: number; ok: boolean; error: string };
	assert.deepEqual(unknown, { id: 2, ok: false, error: 'UNKNOWN_COMMAND' });

	const exited = withTimeout(new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(
		(resolve) => child.once('exit', (code, signal) => resolve({ code, signal }))
	), 'sidecar exit');
	child.stdin.end();
	assert.deepEqual(await exited, { code: 0, signal: null });
	console.log('dispatch sidecar smoke passed');
} catch (error) {
	child.kill();
	if (stderr.trim()) console.error(stderr.trim());
	throw error;
}
