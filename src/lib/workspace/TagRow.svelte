<script lang="ts">
	import { Popover } from 'bits-ui';
	import XIcon from 'lucide-svelte/icons/x';
	import { DURATION, motionMenu, motionScale } from '$lib/motion';
	import Tag from '$lib/ui/Tag.svelte';
	import { PROJECT_COLORS } from './palette';
	import { workspace } from './store.svelte';

	let tagInput = $state('');
	const listId = $props.id();

	const suggestions = $derived(
		workspace.tags.filter((tag) => !workspace.selectedCardTags.some((used) => used.id === tag.id))
	);

	async function submitTag(event: SubmitEvent) {
		event.preventDefault();
		await workspace.addTagToSelectedCard(tagInput);
		tagInput = '';
	}
</script>

<div class="tag-row" aria-label="标签">
	{#each workspace.selectedCardTags as tag (tag.id)}
		<span
			in:motionScale={{ start: 0.9, duration: DURATION.base }}
			out:motionScale={{ start: 0.96, duration: DURATION.fast }}
		>
			<Tag color={tag.color}>
				<Popover.Root>
					<Popover.Trigger>
						{#snippet child({ props })}
							<button {...props} type="button" class="tag-name" aria-label={`${tag.name}，选颜色`}>
								{tag.name}
							</button>
						{/snippet}
					</Popover.Trigger>
					<Popover.Portal>
						<Popover.Content align="start" sideOffset={6} forceMount>
							{#snippet child({ wrapperProps, props, open })}
								{#if open}
									<div {...wrapperProps}>
										<div {...props} class="color-pop" in:motionMenu out:motionMenu>
											{#each PROJECT_COLORS as swatch (swatch.value)}
												<button
													type="button"
													class="color-dot"
													class:active={tag.color === swatch.value}
													style={`--dot: ${swatch.value}`}
													aria-label={swatch.name}
													onclick={() =>
														workspace.setTagColor(
															tag.id,
															tag.color === swatch.value ? null : swatch.value
														)}
												></button>
											{/each}
										</div>
									</div>
								{/if}
							{/snippet}
						</Popover.Content>
					</Popover.Portal>
				</Popover.Root>
				<button
					type="button"
					class="tag-remove"
					aria-label={`移除标签 ${tag.name}`}
					title={`移除标签 ${tag.name}`}
					onclick={() => workspace.removeTagFromSelectedCard(tag.id)}
				>
					<XIcon size={11} strokeWidth={2.4} />
				</button>
			</Tag>
		</span>
	{/each}
	<form class="tag-form" onsubmit={submitTag}>
		<input
			type="text"
			placeholder="+ 标签"
			bind:value={tagInput}
			list={listId}
			maxlength="32"
		/>
		<datalist id={listId}>
			{#each suggestions as tag (tag.id)}
				<option value={tag.name}></option>
			{/each}
		</datalist>
	</form>
</div>

<style>
	.tag-row {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.4rem;
	}

	.tag-name {
		padding: 0;
		border: 0;
		background: transparent;
		color: inherit;
		font: inherit;
		letter-spacing: inherit;
	}

	.tag-remove {
		display: grid;
		width: 1rem;
		height: 1rem;
		place-items: center;
		margin-right: -0.15rem;
		border: 0;
		border-radius: 999px;
		background: transparent;
		color: inherit;
		opacity: 0.65;
		transition: opacity var(--duration-fast) var(--ease-standard);
	}

	.tag-remove:hover {
		opacity: 1;
	}

	.color-pop {
		z-index: 60;
		display: flex;
		gap: 0.4rem;
		padding: 0.5rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: 999px;
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		backdrop-filter: blur(18px) saturate(1.05);
	}

	.color-dot {
		width: 1.25rem;
		height: 1.25rem;
		border: 0;
		border-radius: 999px;
		background: var(--dot);
		transition:
			transform var(--duration-base) var(--ease-spring),
			box-shadow var(--duration-fast) var(--ease-standard);
	}

	.color-dot:hover {
		transform: scale(var(--hover-pop));
	}

	.color-dot.active {
		box-shadow:
			0 0 0 2px var(--color-surface-raised),
			0 0 0 3.5px var(--color-text-strong);
	}

	.tag-form input {
		width: 6.5rem;
		min-height: 1.55rem;
		padding: 0 0.55rem;
		border: 1px dashed var(--color-border-strong);
		border-radius: 999px;
		background: transparent;
		color: var(--color-text);
		font-size: 0.72rem;
		font-weight: 600;
		transition:
			border-color var(--duration-fast) var(--ease-standard),
			background-color var(--duration-fast) var(--ease-standard);
	}

	.tag-form input:focus {
		outline: none;
		border-color: var(--color-focus);
		border-style: solid;
		background: var(--color-surface-solid);
	}

	.tag-form input::placeholder {
		color: var(--color-text-soft);
	}
</style>
