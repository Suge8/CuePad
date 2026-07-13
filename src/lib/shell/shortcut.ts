import { isRegistered, register, unregister } from '@tauri-apps/plugin-global-shortcut';
import { DEFAULT_GLOBAL_SHORTCUT } from './accelerator';

// 显隐逻辑和默认键注册都在 Rust 侧（lib.rs）：窗口隐藏后 webview 可能被
// App Nap/WebKit 冻结，JS handler 不保证执行，后台呼出不能依赖 webview 活性。
// JS 侧只在用户自定义快捷键时注销默认键/注册新键，handler 为占位。
const NOOP = () => undefined;

// 本模块内存会随 webview 重载丢失，而 Rust 进程的注册表不会，
// 所以现状必须惰性从插件真实状态校准，否则重载后会把自己已注册的键误判为被占用
let registered: string | null = null;

// 串行队列：注销/注册/持久化共享同一张注册表，并发交错会导致多键同时生效
let pending: Promise<void> = Promise.resolve();

function enqueue<T>(run: () => Promise<T>): Promise<T> {
	const task = pending.then(run);
	pending = task.then(NOOP, NOOP);
	return task;
}

function messageOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

async function calibrate(target: string): Promise<string | null> {
	if (registered) return registered;
	if (await isRegistered(target)) return target;
	if (await isRegistered(DEFAULT_GLOBAL_SHORTCUT)) return DEFAULT_GLOBAL_SHORTCUT;
	return null;
}

/** 注销旧快捷键并注册新的。失败时尝试恢复旧键，恢复结果与原因都进错误文案。 */
async function switchTo(accelerator: string): Promise<void> {
	const previous = await calibrate(accelerator);
	if (previous === accelerator) {
		registered = accelerator;
		return;
	}
	if (previous) {
		await unregister(previous);
		registered = null;
	}
	try {
		await register(accelerator, NOOP);
		registered = accelerator;
	} catch (cause) {
		let restoreError: unknown = null;
		if (previous) {
			await register(previous, NOOP)
				.then(() => (registered = previous))
				.catch((error: unknown) => (restoreError = error));
		}
		// 恢复结果必须进错误文案，不允许静默：恢复失败意味着当前没有任何快捷键生效
		const restoreNote =
			previous === null
				? ''
				: registered === previous
					? `；已恢复 ${previous}`
					: `；且 ${previous} 未能恢复（${messageOf(restoreError)}），当前无快捷键生效`;
		throw new Error(`注册全局快捷键 ${accelerator} 失败，可能已被其他应用占用${restoreNote}`, {
			cause
		});
	}
}

export function applyGlobalShortcut(accelerator: string): Promise<void> {
	return enqueue(() => switchTo(accelerator));
}

/**
 * 完整更新事务：注册 → 持久化 → 持久化失败回滚注册。
 * 整体串行，运行时注册表与持久化值不会因并发交错而分叉。
 */
export function updateGlobalShortcut(
	accelerator: string,
	persist: (accelerator: string) => Promise<void>
): Promise<void> {
	return enqueue(async () => {
		const previous = await calibrate(accelerator);
		await switchTo(accelerator);
		try {
			await persist(accelerator);
		} catch (error) {
			// 回滚到事务前的真实状态：有旧键则切回旧键；此前无键则注销刚注册的新键
			try {
				if (previous && previous !== accelerator) {
					await switchTo(previous);
				} else if (previous === null) {
					await unregister(accelerator);
					registered = null;
				}
			} catch (rollbackError) {
				const action = previous ? `回滚 ${previous}` : `注销 ${accelerator}`;
				throw new Error(
					`保存失败：${messageOf(error)}；且${action} 失败：${messageOf(rollbackError)}`,
					{ cause: rollbackError }
				);
			}
			throw error;
		}
	});
}
