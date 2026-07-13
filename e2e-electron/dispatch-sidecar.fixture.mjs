#!/usr/bin/env node
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const logPath = process.env.CUEPAD_TEST_DISPATCH_LOG;
if (!logPath) throw new Error('CUEPAD_TEST_DISPATCH_LOG 未设置');
const input = createInterface({ input: process.stdin });
const log = (value) => appendFileSync(logPath, `${JSON.stringify({ pid: process.pid, ...value })}\n`);
const respond = (response) => process.stdout.write(`${JSON.stringify(response)}\n`);

log({ event: 'start' });
input.on('line', (line) => {
	const request = JSON.parse(line);
	log({ event: 'request', request });
	if (request.cmd === 'target') {
		if (request.prepare && request.bundleId === 'test.missing') {
			respond({ id: request.id, ok: false, error: 'DISPATCH_TARGET_UNAVAILABLE' });
			return;
		}
		respond({
			id: request.id,
			ok: true,
			data: {
				bundleId: request.bundleId ?? 'com.apple.finder',
				name: `Fixture ${process.pid}`
			}
		});
		return;
	}
	if (request.cmd === 'targets') {
		respond({
			id: request.id,
			ok: true,
			data: [{ bundleId: 'com.apple.finder', name: 'Finder' }]
		});
		return;
	}
	if (request.cmd === 'dispatch' && request.bundleId === 'test.crash') process.exit(86);
	if (request.cmd === 'dispatch' && request.bundleId === 'test.fail') {
		respond({ id: request.id, ok: false, error: 'DISPATCH_TARGET_UNAVAILABLE' });
		return;
	}
	respond({ id: request.id, ok: true, data: null });
});
input.on('close', () => log({ event: 'close' }));
