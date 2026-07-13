<script lang="ts">
	import { Dialog } from 'bits-ui';
	import XIcon from 'lucide-svelte/icons/x';
	import { fillVariables, parseVariables } from '$lib/editor/variables';
	import { motionDialog, motionFade } from '$lib/motion';
	import Button from '$lib/ui/Button.svelte';
	import { VARIABLE_FILL_EVENT, type VariableFillRequest } from './dispatch';

	let request = $state<VariableFillRequest | null>(null);
	let values = $state<Record<string, string>>({});
	const variables = $derived(request ? parseVariables(request.text) : []);

	function storageKey(cardId: number): string {
		return `cuepad:vars:${cardId}`;
	}

	function readRemembered(cardId: number): Record<string, string> {
		try {
			const parsed: unknown = JSON.parse(localStorage.getItem(storageKey(cardId)) ?? '{}');
			if (typeof parsed !== 'object' || parsed === null) return {};
			return Object.fromEntries(
				Object.entries(parsed).filter((entry): entry is [string, string] => typeof entry[1] === 'string')
			);
		} catch {
			return {};
		}
	}

	function onRequest(event: Event) {
		const next = (event as CustomEvent<VariableFillRequest>).detail;
		next.handled = true;
		request?.resolve(null);
		request = next;
		const remembered = readRemembered(next.cardId);
		values = Object.fromEntries(
			parseVariables(next.text).map((variable) => [variable, remembered[variable] ?? ''])
		);
	}

	$effect(() => {
		window.addEventListener(VARIABLE_FILL_EVENT, onRequest);
		return () => window.removeEventListener(VARIABLE_FILL_EVENT, onRequest);
	});

	function cancel() {
		const active = request;
		if (!active) return;
		request = null;
		active.resolve(null);
	}

	function submit() {
		const active = request;
		if (!active) return;
		const remembered = { ...readRemembered(active.cardId), ...values };
		try {
			localStorage.setItem(storageKey(active.cardId), JSON.stringify(remembered));
		} catch (error) {
			console.warn('variable values write failed', error);
		}
		request = null;
		active.resolve(fillVariables(active.text, values));
	}
</script>

<Dialog.Root open={request !== null} onOpenChange={(open) => !open && cancel()}>
	<Dialog.Portal>
		<Dialog.Overlay forceMount>
			{#snippet child({ props, open })}
				{#if open}
					<div {...props} class="overlay" in:motionFade out:motionFade></div>
				{/if}
			{/snippet}
		</Dialog.Overlay>
		<Dialog.Content forceMount>
			{#snippet child({ props, open })}
				{#if open && request}
					<section {...props} class="variable-card" in:motionDialog out:motionDialog>
						<div class="dialog-head">
							<div>
								<Dialog.Title class="dialog-title">填写变量</Dialog.Title>
								<Dialog.Description class="dialog-description">
									填写后{request.intent === 'copy' ? '复制' : '投送'}
								</Dialog.Description>
							</div>
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
								submit();
							}}
						>
							<div class="fields">
								{#each variables as variable, index (variable)}
									<label>
										<span>{variable}</span>
										<!-- svelte-ignore a11y_autofocus -->
										<input
											type="text"
											autofocus={index === 0}
											aria-label={variable}
											placeholder={`输入${variable}`}
											bind:value={values[variable]}
										/>
									</label>
								{/each}
							</div>
							<div class="actions">
								<Button variant="ghost" onclick={cancel}>取消</Button>
								<Button variant="primary" type="submit">
									{request.intent === 'copy' ? '复制' : '投送'}
								</Button>
							</div>
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
		z-index: 100;
		background: rgba(15, 17, 16, 0.34);
		backdrop-filter: blur(8px);
	}

	.variable-card {
		position: fixed;
		left: 50%;
		top: 50%;
		z-index: 110;
		translate: -50% -50%;
		display: grid;
		width: min(28rem, calc(100vw - 2rem));
		max-height: min(36rem, calc(100dvh - 3rem));
		padding: 1.1rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-panel);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
	}

	.dialog-head {
		display: flex;
		align-items: start;
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

	:global(.dialog-description) {
		margin: 0.25rem 0 0;
		font-size: 0.78rem;
		color: var(--color-text-muted);
	}

	form,
	.fields {
		display: grid;
		gap: 0.85rem;
		min-height: 0;
	}

	.fields {
		overflow-y: auto;
	}

	label {
		display: grid;
		gap: 0.4rem;
	}

	label span {
		font-size: 0.78rem;
		font-weight: 600;
		color: var(--color-text);
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

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.4rem;
		padding-top: 0.15rem;
	}
</style>
