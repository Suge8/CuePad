import { createServer, type AddressInfo } from 'node:net';
import { resolve } from 'node:path';
import type { Options } from '@wdio/types';

const application = resolve('e2e-tauri/launch.sh');

// 每次运行独立空闲端口：并行验收互不冲突，也不会碰到其他进程的监听
const embeddedPort = await new Promise<number>((resolvePort, reject) => {
	const probe = createServer();
	probe.once('error', reject);
	probe.listen(0, '127.0.0.1', () => {
		const { port } = probe.address() as AddressInfo;
		probe.close(() => resolvePort(port));
	});
});

export const config: Options.Testrunner = {
	runner: 'local',
	specs: [
		'./e2e-tauri/accessibility.e2e.ts',
		'./e2e-tauri/workspace.e2e.ts',
		'./e2e-tauri/workspace-restart.e2e.ts'
	],
	maxInstances: 1,
	capabilities: [
		{
			browserName: 'tauri',
			'tauri:options': { application }
		}
	],
	services: [
		[
			'@wdio/tauri-service',
			{
				appBinaryPath: application,
				driverProvider: 'embedded',
				embeddedPort,
				captureBackendLogs: true,
				captureFrontendLogs: true
			}
		]
	],
	// Node 26 内建 Request 拒绝 Fetch 规范禁止头；上游 webdriverio#15265 修复前在此剔除
	transformRequest: (requestOptions) => {
		const headers = requestOptions.headers;
		if (headers instanceof Headers) {
			headers.delete('Connection');
			headers.delete('Content-Length');
		}
		return requestOptions;
	},
	logLevel: 'error',
	reporters: ['spec'],
	framework: 'mocha',
	waitforTimeout: 15_000,
	connectionRetryTimeout: 60_000,
	connectionRetryCount: 1,
	mochaOpts: {
		ui: 'bdd',
		timeout: 30_000
	}
};
