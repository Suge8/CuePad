<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { motionDialog, motionFade } from '$lib/motion';
	import XIcon from 'lucide-svelte/icons/x';
	import type { Project } from '$lib/db';
	import Button from '$lib/ui/Button.svelte';
	import PalettePicker from '$lib/ui/PalettePicker.svelte';
	import { PROJECT_COLORS } from './palette';
	import { workspace } from './store.svelte';

	type Props = {
		open: boolean;
		/** null = 新建 */
		project: Project | null;
		onClose: () => void;
	};

	let { open, project, onClose }: Props = $props();

	let name = $state('');
	let color = $state(PROJECT_COLORS[0].value);
	let icon = $state<string | null>(null);
	let saving = $state(false);

	$effect(() => {
		if (!open) return;
		name = project?.name ?? '';
		color = project?.color ?? PROJECT_COLORS[0].value;
		icon = project?.icon ?? null;
	});

	async function save() {
		if (saving) return;
		saving = true;
		const input = { name: name.trim() || null, color, icon };
		const saved = project
			? await workspace.updateProject(project.id, input)
			: await workspace.createProject(input);
		saving = false;
		// 失败时保留弹窗与输入（错误已由 toast 展示），成功才关闭
		if (saved) onClose();
	}
</script>

<Dialog.Root {open} onOpenChange={(next) => !next && onClose()}>
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
					<section {...props} class="dialog-card" in:motionDialog out:motionDialog>
						<div class="dialog-head">
							<Dialog.Title class="dialog-title">
								{project ? '编辑项目' : '新建项目'}
							</Dialog.Title>
							<Dialog.Close>
								{#snippet child({ props: closeProps })}
									<Button {...closeProps} variant="ghost" size="icon" aria-label="关闭" title="关闭">
										<XIcon size={17} strokeWidth={2} />
									</Button>
								{/snippet}
							</Dialog.Close>
						</div>

						<form
							onsubmit={(event) => {
								event.preventDefault();
								save();
							}}
						>
							<!-- svelte-ignore a11y_autofocus -->
							<input type="text" placeholder="项目名称" autofocus bind:value={name} />

							<PalettePicker
								selectedColor={color}
								selectedIcon={icon}
								onColorChange={(next) => (color = next)}
								onIconChange={(next) => (icon = next)}
							/>

							<Button variant="primary" type="submit" class="submit" disabled={saving}>
								{project ? '保存' : '创建项目'}
							</Button>
						</form>
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

	.dialog-card {
		position: fixed;
		left: 50%;
		top: 50%;
		z-index: 80;
		translate: -50% -50%;
		width: min(26rem, calc(100vw - 2rem));
		padding: 1.1rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-panel);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
	}

	.dialog-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 1rem;
	}

	:global(.dialog-title) {
		margin: 0;
		font-size: 1.3rem;
		font-weight: 600;
		letter-spacing: -0.04em;
		color: var(--color-text-strong);
	}

	form {
		display: grid;
		gap: 1rem;
	}

	form :global(.submit) {
		width: 100%;
		min-height: 2.7rem;
		border-radius: 999px;
	}

	input {
		min-height: 2.6rem;
		padding: 0 0.8rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-control);
		background: var(--color-surface-solid);
		color: var(--color-text-strong);
		transition:
			border-color var(--duration-fast) var(--ease-standard),
			box-shadow var(--duration-fast) var(--ease-standard);
	}

	input:focus {
		outline: none;
		border-color: var(--color-focus);
		box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-focus) 40%, transparent);
	}

	input::placeholder {
		color: var(--color-text-soft);
	}


</style>
