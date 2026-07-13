import { expect, test } from 'bun:test';

// 模拟主进程注册表：跨 renderer 重载（模块内存丢失）持续存在
const registry = new Set<string>();
let failRegister: string[] = [];
let failUnregister: string[] = [];

Object.defineProperty(globalThis, 'window', {
	configurable: true,
	value: {
		cuepad: {
			shortcut: {
				isRegistered: async (accelerator: string) => registry.has(accelerator),
				register: async (accelerator: string) => {
					if (failRegister.includes(accelerator)) throw new Error(`taken: ${accelerator}`);
					registry.add(accelerator);
				},
				unregister: async (accelerator: string) => {
					if (failUnregister.includes(accelerator)) throw new Error(`stuck: ${accelerator}`);
					registry.delete(accelerator);
				}
			}
		}
	}
});

const { applyGlobalShortcut, updateGlobalShortcut } = await import('../src/lib/shell/shortcut');
const { DEFAULT_GLOBAL_SHORTCUT } = await import('../src/lib/shell/accelerator');

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// 注意：shortcut.ts 持有模块级状态，以下测试按顺序构成一个连续场景

test('webview 重载校准：目标键已在注册表时不重复注册、不报占用', async () => {
	registry.add('Control+Alt+KeyU'); // 上个 webview 会话注册的自定义键
	await applyGlobalShortcut('Control+Alt+KeyU');
	expect([...registry]).toEqual(['Control+Alt+KeyU']);
});

test('切换快捷键：注销旧键并注册新键', async () => {
	await applyGlobalShortcut('Control+KeyJ');
	expect([...registry]).toEqual(['Control+KeyJ']);
});

test('注册失败：恢复旧键并在错误中说明', async () => {
	failRegister = ['Control+KeyX'];
	await expect(applyGlobalShortcut('Control+KeyX')).rejects.toThrow(/已恢复 Control\+KeyJ/);
	expect([...registry]).toEqual(['Control+KeyJ']);
});

test('注册失败且旧键恢复失败：错误明示无快捷键生效，并保留两层原因', async () => {
	failRegister = ['Control+KeyY', 'Control+KeyJ'];
	const error = await applyGlobalShortcut('Control+KeyY').then(
		() => null,
		(caught: Error) => caught
	);
	expect(error?.message).toContain('Control+KeyJ 未能恢复');
	expect(error?.message).toContain('taken: Control+KeyJ');
	expect(error?.message).toContain('当前无快捷键生效');
	expect((error?.cause as Error).message).toContain('taken: Control+KeyY');
	expect(registry.size).toBe(0);
});

test('校准回退：目标键不在但默认键在注册表时，从默认键切换', async () => {
	failRegister = [];
	registry.add(DEFAULT_GLOBAL_SHORTCUT); // 模拟主进程启动注册的默认键
	await applyGlobalShortcut('Control+KeyZ');
	expect([...registry]).toEqual(['Control+KeyZ']);
});

test('并发注册被串行化：最终只有最后一个键生效', async () => {
	await Promise.all([applyGlobalShortcut('Control+KeyB'), applyGlobalShortcut('Control+KeyC')]);
	expect([...registry]).toEqual(['Control+KeyC']);
});

test('更新事务：注册成功且持久化成功', async () => {
	const persisted: string[] = [];
	await updateGlobalShortcut('Control+KeyD', async (value) => {
		persisted.push(value);
	});
	expect([...registry]).toEqual(['Control+KeyD']);
	expect(persisted).toEqual(['Control+KeyD']);
});

test('更新事务：持久化失败时回滚注册，抛出原始错误', async () => {
	await expect(
		updateGlobalShortcut('Control+KeyE', async () => {
			throw new Error('db down');
		})
	).rejects.toThrow('db down');
	expect([...registry]).toEqual(['Control+KeyD']);
});

test('更新事务：持久化失败且回滚失败，两层原因都进错误', async () => {
	failRegister = ['Control+KeyD'];
	const error = await updateGlobalShortcut('Control+KeyF', async () => {
		throw new Error('db down');
	}).then(
		() => null,
		(caught: Error) => caught
	);
	failRegister = [];
	expect(error?.message).toContain('保存失败：db down');
	expect(error?.message).toContain('且回滚 Control+KeyD 失败');
});

test('无旧键时持久化失败：注销刚注册的新键，回到无键状态', async () => {
	// 先制造「当前无任何键生效」：注册失败且旧键（上个测试末态 KeyF）恢复失败
	failRegister = ['Control+KeyI', 'Control+KeyF'];
	await applyGlobalShortcut('Control+KeyI').then(
		() => null,
		() => null
	);
	failRegister = [];
	expect(registry.size).toBe(0);

	await expect(
		updateGlobalShortcut('Control+KeyK', async () => {
			throw new Error('db down');
		})
	).rejects.toThrow('db down');
	expect(registry.size).toBe(0);
});

test('无旧键且注销新键失败：两层原因都进错误', async () => {
	failUnregister = ['Control+KeyL'];
	const error = await updateGlobalShortcut('Control+KeyL', async () => {
		throw new Error('db down');
	}).then(
		() => null,
		(caught: Error) => caught
	);
	failUnregister = [];
	expect(error?.message).toContain('保存失败：db down');
	expect(error?.message).toContain('且注销 Control+KeyL 失败：stuck: Control+KeyL');
	// 注销失败：新键仍在注册表里，后续操作从真实状态继续
	expect([...registry]).toEqual(['Control+KeyL']);
	await applyGlobalShortcut('Control+KeyM');
	expect([...registry]).toEqual(['Control+KeyM']);
});

test('并发更新被串行化：持久化顺序与调用顺序一致，最后一次调用胜出', async () => {
	const persisted: string[] = [];
	await Promise.all([
		updateGlobalShortcut('Control+KeyG', async (value) => {
			await delay(30); // 第一笔持久化更慢，若未串行则乱序
			persisted.push(value);
		}),
		updateGlobalShortcut('Control+KeyH', async (value) => {
			persisted.push(value);
		})
	]);
	expect(persisted).toEqual(['Control+KeyG', 'Control+KeyH']);
	expect([...registry]).toEqual(['Control+KeyH']);
});
