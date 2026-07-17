import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { expect, test } from 'bun:test';
import { DispatchSidecar } from './sidecar';

const FIXTURE = `#!/usr/bin/env node
const { appendFileSync } = require('node:fs');
const readline = require('node:readline');
const logPath = process.env.CUEPAD_SIDECAR_FIXTURE_LOG;
const log = (value) => appendFileSync(logPath, JSON.stringify({ pid: process.pid, ...value }) + '\\n');
const input = readline.createInterface({ input: process.stdin });
log({ event: 'start' });
input.on('line', (line) => {
  const request = JSON.parse(line);
  log({ event: 'request', request });
  if (request.cmd === 'dispatch' && request.bundleId === 'test.crash') process.exit(86);
  const data = request.cmd === 'targets'
    ? [{ bundleId: 'com.apple.finder', name: 'Finder' }]
    : request.cmd === 'target'
      ? { bundleId: 'com.example.fixture', name: 'Fixture ' + process.pid }
      : null;
  process.stdout.write(JSON.stringify({ id: request.id, ok: true, data }) + '\\n');
});
input.on('close', () => log({ event: 'close' }));
`;

test('sidecar 请求全链路串行，异常退出后在下次调用重启', async () => {
	const directory = await mkdtemp(path.join(tmpdir(), 'cuepad-sidecar-'));
	const executablePath = path.join(directory, 'fixture.cjs');
	const logPath = path.join(directory, 'fixture.log');
	await writeFile(executablePath, FIXTURE);
	await chmod(executablePath, 0o755);
	const previousLogPath = process.env.CUEPAD_SIDECAR_FIXTURE_LOG;
	process.env.CUEPAD_SIDECAR_FIXTURE_LOG = logPath;
	const sidecar = new DispatchSidecar({ executablePath, arguments: [] });
	try {
		const firstTarget = await sidecar.target();
		const firstPid = Number(firstTarget?.name.replace('Fixture ', ''));
		const prepared: string[] = [];
		await Promise.all([
			sidecar.dispatch('first', false, () => prepared.push('first')),
			sidecar.dispatch('second', false, () => prepared.push('second'))
		]);
		expect(prepared).toEqual(['first', 'second']);

		await expect(sidecar.dispatch('test.crash', false, () => prepared.push('crash')))
			.rejects.toThrow('DISPATCH_SIDECAR_EXITED:code 86');
		const restartedTarget = await sidecar.target();
		const restartedPid = Number(restartedTarget?.name.replace('Fixture ', ''));
		expect(restartedPid).not.toBe(firstPid);
		await sidecar.close();

		const records = (await readFile(logPath, 'utf8')).trim().split('\n').map(JSON.parse);
		const requestOrder = records
			.filter((record) => record.event === 'request')
			.map((record) => [record.request.cmd, record.request.bundleId, record.request.prepare]);
		expect(requestOrder).toEqual([
			['target', undefined, undefined],
			['target', 'first', true],
			['dispatch', 'first', undefined],
			['target', 'second', true],
			['dispatch', 'second', undefined],
			['target', 'test.crash', true],
			['dispatch', 'test.crash', undefined],
			['target', undefined, undefined]
		]);
		expect(records).toContainEqual({ pid: restartedPid, event: 'close' });
	} finally {
		await sidecar.close();
		if (previousLogPath === undefined) delete process.env.CUEPAD_SIDECAR_FIXTURE_LOG;
		else process.env.CUEPAD_SIDECAR_FIXTURE_LOG = previousLogPath;
		await rm(directory, { recursive: true, force: true });
	}
});
