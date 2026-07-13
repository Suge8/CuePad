<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { DURATION, motionDialog, motionFade, motionFly } from '$lib/motion';
	import FolderOpenIcon from 'lucide-svelte/icons/folder-open';
	import MonitorIcon from 'lucide-svelte/icons/monitor';
	import MoonIcon from 'lucide-svelte/icons/moon';
	import SunIcon from 'lucide-svelte/icons/sun';
	import Trash2Icon from 'lucide-svelte/icons/trash-2';
	import XIcon from 'lucide-svelte/icons/x';
	import type { ThemeSetting } from '$lib/db';
	import { acceleratorFromStroke, formatAccelerator } from '$lib/shell/accelerator';
	import Button from '$lib/ui/Button.svelte';
	import Mascot from '$lib/ui/Mascot.svelte';
	import Sparkle from '$lib/ui/Sparkle.svelte';
	import { workspace } from './store.svelte';

	const THEME_OPTIONS: { value: ThemeSetting; label: string; icon: typeof SunIcon }[] = [
		{ value: 'system', label: '系统', icon: MonitorIcon },
		{ value: 'light', label: '浅色', icon: SunIcon },
		{ value: 'dark', label: '深色', icon: MoonIcon }
	];

	const SHORTCUT_RULE = '至少一个修饰键（⌘ ⌥ ⌃ ⇧）+ 一个主键（字母 / 数字 / F1–F12 / 空格 / 方向键等）；Esc 取消';

	let recording = $state(false);
	let shortcutError = $state('');
	let databasePath = $state('');
	let appVersion = $state('');

	$effect(() => {
		if (!workspace.settingsOpen) {
			recording = false;
			return;
		}
		shortcutError = '';
		if (!databasePath) {
			void window.cuepad.app.databasePath().then((path) => (databasePath = path));
		}
		if (!appVersion) {
			void window.cuepad.app.version().then((version) => (appVersion = version));
		}
	});

	// 录制直接绑在聚焦的按钮上（target 阶段），page 层对 data-shortcut-recorder 内的事件放行，
	// 避免与 Cmd/Ctrl+F 命令面板拦截冲突；失焦即取消录制
	function onRecordKeydown(event: KeyboardEvent) {
		event.preventDefault();
		event.stopPropagation();
		if (event.key === 'Escape') {
			recording = false;
			return;
		}
		const accelerator = acceleratorFromStroke(event);
		if (!accelerator) return; // 纯修饰键或不支持的主键，继续等待
		recording = false;
		workspace.setGlobalShortcut(accelerator).then(
			() => (shortcutError = ''),
			(error) => (shortcutError = error instanceof Error ? error.message : String(error))
		);
	}

	function autofocus(node: HTMLElement) {
		node.focus();
	}

	// 回收站是低频操作，入口收在设置页；先关设置再开，避免两层对话框叠加
	function openTrash() {
		workspace.settingsOpen = false;
		workspace.trashOpen = true;
	}

	async function revealDataFile() {
		try {
			await window.cuepad.app.revealDataFile();
		} catch (error) {
			workspace.showToast('打开失败', {
				detail: error instanceof Error ? error.message : String(error),
				tone: 'danger'
			});
		}
	}
</script>

<Dialog.Root open={workspace.settingsOpen} onOpenChange={(next) => (workspace.settingsOpen = next)}>
	<Dialog.Portal>
		<Dialog.Overlay forceMount>
			{#snippet child({ props, open: isOpen })}
				{#if isOpen}
					<div {...props} class="overlay" in:motionFade out:motionFade></div>
				{/if}
			{/snippet}
		</Dialog.Overlay>
		<Dialog.Content forceMount>
			{#snippet child({ props, open: isOpen })}
				{#if isOpen}
					<section {...props} class="settings-card" in:motionDialog out:motionDialog>
						<div class="settings-head">
							<span class="head-title">
								<Dialog.Title class="settings-title">设置</Dialog.Title>
								<span class="head-spark" aria-hidden="true"><Sparkle size={11} /></span>
							</span>
							<Dialog.Close>
								{#snippet child({ props: closeProps })}
									<Button {...closeProps} variant="ghost" size="icon" aria-label="关闭" title="关闭">
										<XIcon size={17} strokeWidth={2} />
									</Button>
								{/snippet}
							</Dialog.Close>
						</div>

						<div class="settings-body">
							<div class="setting">
								<div class="setting-text">
									<strong>主题</strong>
								</div>
								<div class="theme-switch" role="group" aria-label="主题">
									{#each THEME_OPTIONS as option (option.value)}
										{@const Icon = option.icon}
										<button
											type="button"
											class:active={workspace.theme === option.value}
											aria-pressed={workspace.theme === option.value}
											onclick={() => workspace.setTheme(option.value)}
										>
											<Icon size={14} strokeWidth={2} />
											{option.label}
										</button>
									{/each}
								</div>
							</div>

							<div class="setting">
								<div class="setting-text">
									<strong>显示 / 隐藏</strong>
									{#if shortcutError}
										<p
											class="setting-error"
											role="alert"
											in:motionFly={{ y: -4, duration: DURATION.base }}
										out:motionFly={{ y: -2, duration: DURATION.fast }}
										>
											{shortcutError}
										</p>
									{/if}
								</div>
								{#if recording}
									<button
										type="button"
										class="shortcut-chip recording"
										data-shortcut-recorder
										title={SHORTCUT_RULE}
										use:autofocus
										onkeydown={onRecordKeydown}
										onblur={() => (recording = false)}
									>
										按下新组合…
									</button>
								{:else}
									<button
										type="button"
										class="shortcut-chip"
										title={`点击重新录制：${SHORTCUT_RULE}`}
										aria-label="重新录制全局快捷键"
										onclick={() => {
											shortcutError = '';
											recording = true;
										}}
									>
										{formatAccelerator(workspace.globalShortcut)}
									</button>
								{/if}
							</div>

							<div class="setting">
								<div class="setting-text">
									<strong>回收站</strong>
									<small>已删除的项目和卡片</small>
								</div>
								<Button
									variant="ghost"
									size="icon"
									aria-label="打开回收站"
									title="打开回收站"
									onclick={openTrash}
								>
									<Trash2Icon size={14} strokeWidth={2} />
								</Button>
							</div>

							<div class="setting">
								<div class="setting-text">
									<strong>数据文件</strong>
									<small class="path" title={databasePath}>{databasePath || '…'}</small>
								</div>
								<Button
									variant="ghost"
									size="icon"
									aria-label="在 Finder 中显示"
									title="在 Finder 中显示"
									onclick={revealDataFile}
								>
									<FolderOpenIcon size={14} strokeWidth={2} />
								</Button>
							</div>

							<div class="settings-about">
								<Mascot pose="hello" size={92} />
								<p>CuePad{appVersion ? ` v${appVersion}` : ''}</p>
							</div>
						</div>
					</section>
				{/if}
			{/snippet}
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	.overlay {
		position: fixed;
		inset: 0;
		z-index: 70;
		background: rgba(15, 17, 16, 0.34);
		backdrop-filter: blur(8px);
	}

	.settings-card {
		position: fixed;
		left: 50%;
		top: 50%;
		z-index: 80;
		translate: -50% -50%;
		display: grid;
		grid-template-rows: auto minmax(0, 1fr);
		width: min(32rem, calc(100vw - 2rem));
		max-height: min(36rem, calc(100dvh - 3rem));
		padding: 1.1rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-panel);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
	}

	.settings-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 0.85rem;
	}

	.head-title {
		display: inline-flex;
		align-items: start;
		gap: 0.3rem;
	}

	.head-spark {
		color: var(--color-border-strong);
	}

	:global(.settings-title) {
		margin: 0;
		font-size: 1.3rem;
		font-weight: 600;
		letter-spacing: -0.04em;
		color: var(--color-text-strong);
	}

	.settings-body {
		display: grid;
		align-content: start;
		gap: 0.5rem;
		overflow-y: auto;
		padding-right: 0.2rem;
	}

	.setting {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		padding: 0.75rem 0.8rem;
		border-radius: var(--radius-card);
		background: var(--color-surface-muted);
	}

	.setting-text {
		display: grid;
		gap: 0.25rem;
		min-width: 0;
	}

	.setting-text strong {
		font-size: 0.88rem;
		font-weight: 600;
		letter-spacing: -0.015em;
		color: var(--color-text-strong);
	}

	.setting-text small {
		font-size: 0.76rem;
		line-height: 1.55;
		color: var(--color-text-muted);
	}

	.settings-about {
		display: grid;
		justify-items: center;
		gap: 0.5rem;
		padding: 1.1rem 0 0.4rem;
		font-size: 0.76rem;
		letter-spacing: -0.01em;
		color: var(--color-text-muted);
		user-select: none;
	}

	.setting-text .path {
		overflow: hidden;
		font-family: var(--font-mono);
		font-size: 0.7rem;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.setting-error {
		margin: 0;
		font-size: 0.76rem;
		line-height: 1.5;
		color: var(--color-danger);
	}

	.theme-switch {
		display: flex;
		gap: 0.25rem;
		padding: 0.2rem;
		border-radius: 0.8rem;
		background: var(--color-surface-solid);
		box-shadow: var(--shadow-control);
	}

	.theme-switch button {
		display: inline-flex;
		align-items: center;
		gap: 0.35rem;
		min-height: 1.9rem;
		padding: 0 0.6rem;
		border: 0;
		border-radius: 0.6rem;
		background: transparent;
		color: var(--color-text-muted);
		font-size: 0.78rem;
		font-weight: 500;
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard);
	}

	.theme-switch button.active {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.shortcut-chip {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		min-height: 2.1rem;
		max-width: 12rem;
		padding: 0 0.85rem;
		border: 0;
		border-radius: 999px;
		background: var(--color-surface-solid);
		color: var(--color-text-strong);
		font-family: var(--font-mono);
		font-size: 0.78rem;
		font-weight: 600;
		letter-spacing: 0.06em;
		white-space: nowrap;
		box-shadow: 0 0 0 1px var(--color-border-subtle) inset;
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard),
			box-shadow var(--duration-fast) var(--ease-standard);
	}

	.shortcut-chip:hover {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.shortcut-chip.recording {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
		font-family: var(--font-sans);
		font-weight: 500;
		letter-spacing: 0;
		box-shadow: 0 0 0 2px var(--color-focus) inset;
		animation: fx-recording-pulse 1.2s var(--ease-standard) infinite;
	}

	@media (prefers-reduced-motion: reduce) {
		.shortcut-chip.recording {
			animation: none;
		}
	}
</style>
