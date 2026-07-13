import type { DispatchApp } from '../../../electron/shared/bridge-types';
import { parseVariables } from '$lib/editor/variables';
import { IS_MAC } from '$lib/shell/accelerator';
import { workspace } from './store.svelte';

export const dispatchAvailable = IS_MAC;
export const DISPATCH_TARGET_EVENT = 'cuepad:dispatch-target';
export const VARIABLE_FILL_EVENT = 'cuepad:fill-variables';
const PINNED_TARGET_KEY = 'cuepad:dispatch-target';

export type { DispatchApp };

export type PromptIntent = 'copy' | 'dispatch';
export type VariableFillRequest = {
	text: string;
	cardId: number;
	intent: PromptIntent;
	handled: boolean;
	resolve: (text: string | null) => void;
};

type PromptOutput = {
	text: string;
	cardId: number;
	label: string;
};

type PinnedTarget = DispatchApp & { bundleId: string };

function messageOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

function prepareText(output: PromptOutput, intent: PromptIntent): Promise<string | null> {
	if (parseVariables(output.text).length === 0) return Promise.resolve(output.text);
	return new Promise((resolve) => {
		const request: VariableFillRequest = {
			text: output.text,
			cardId: output.cardId,
			intent,
			handled: false,
			resolve
		};
		window.dispatchEvent(new CustomEvent(VARIABLE_FILL_EVENT, { detail: request }));
		if (request.handled) return;
		resolve(null);
		workspace.showToast('变量表单未就绪', { tone: 'danger' });
	});
}

export function dispatchPinnedTarget(): PinnedTarget | null {
	try {
		const parsed: unknown = JSON.parse(localStorage.getItem(PINNED_TARGET_KEY) ?? 'null');
		if (typeof parsed !== 'object' || parsed === null) return null;
		const target = parsed as Partial<DispatchApp>;
		if (typeof target.bundleId !== 'string' || typeof target.name !== 'string') return null;
		return { bundleId: target.bundleId, name: target.name };
	} catch {
		return null;
	}
}

export function setDispatchTarget(target: DispatchApp | null): void {
	try {
		if (target?.bundleId) localStorage.setItem(PINNED_TARGET_KEY, JSON.stringify(target));
		else localStorage.removeItem(PINNED_TARGET_KEY);
		window.dispatchEvent(new Event(DISPATCH_TARGET_EVENT));
	} catch (error) {
		workspace.showToast('投送目标未保存', { detail: messageOf(error), tone: 'danger' });
	}
}

export async function dispatchRecentTarget(): Promise<DispatchApp | null> {
	if (!dispatchAvailable) return null;
	try {
		return await window.cuepad.dispatch.target();
	} catch (error) {
		workspace.showToast('读取投送目标失败', { detail: messageOf(error), tone: 'danger' });
		return null;
	}
}

export function dispatchTarget(): Promise<DispatchApp | null> {
	const pinned = dispatchPinnedTarget();
	return pinned ? Promise.resolve(pinned) : dispatchRecentTarget();
}

export async function dispatchTargets(): Promise<DispatchApp[]> {
	if (!dispatchAvailable) return [];
	try {
		return await window.cuepad.dispatch.targets();
	} catch (error) {
		workspace.showToast('读取应用列表失败', { detail: messageOf(error), tone: 'danger' });
		return [];
	}
}

// 剪贴板是共享资源：复制与投送（写剪贴板→粘贴）在途时互斥，
// 否则交错覆盖会让目标应用粘到错误文本；也兼作快速双击防重
let clipboardInFlight = false;

export async function copyPrompt(output: PromptOutput): Promise<void> {
	if (clipboardInFlight) return;
	clipboardInFlight = true;
	try {
		const text = await prepareText(output, 'copy');
		if (text === null) return;
		await window.cuepad.clipboard.writeText(text);
		workspace.showToast(`已复制${output.label}`, { icon: 'copy', tone: 'success' });
	} catch (error) {
		workspace.showToast('复制失败', { detail: messageOf(error), tone: 'danger' });
	} finally {
		clipboardInFlight = false;
	}
}

export async function dispatchPrompt(output: PromptOutput): Promise<void> {
	if (!dispatchAvailable || clipboardInFlight) return;
	clipboardInFlight = true;
	try {
		await runDispatch(output);
	} finally {
		clipboardInFlight = false;
	}
}

async function runDispatch(output: PromptOutput): Promise<void> {
	const text = await prepareText(output, 'dispatch');
	if (text === null) return;
	try {
		await window.cuepad.dispatch.text(text, dispatchPinnedTarget()?.bundleId ?? null);
	} catch (error) {
		const message = messageOf(error);
		if (message.includes('ACCESSIBILITY_PERMISSION_REQUIRED')) {
			workspace.showToast('需要辅助功能权限', {
				detail: '打开「系统设置 → 隐私与安全性 → 辅助功能」，允许 CuePad 后重试',
				tone: 'danger'
			});
			return;
		}
		if (message.includes('NO_DISPATCH_TARGET') || message.includes('DISPATCH_TARGET_UNAVAILABLE')) {
			workspace.showToast('找不到投送目标', {
				detail: '固定目标可能未运行；使用“上一个应用”时，请先聚焦输入框再呼出 CuePad',
				tone: 'danger'
			});
			return;
		}
		workspace.showToast('投送失败', { detail: message, tone: 'danger' });
	}
}
