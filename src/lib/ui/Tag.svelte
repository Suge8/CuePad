<script lang="ts">
	import { DURATION, motionScale } from '$lib/motion';
	import type { Snippet } from 'svelte';
	type Props = {
		/** 色板色值；空则中性灰 */
		color?: string | null;
		children?: Snippet;
	};

	let { color = null, children }: Props = $props();
</script>

<span class="tag" class:colored={!!color} style={color ? `--tag-color: ${color}` : ''}>
	{#if color}<span
			class="tag-dot"
			aria-hidden="true"
			in:motionScale={{ start: 0.4, duration: DURATION.base }}
			out:motionScale={{ start: 0.8, duration: DURATION.fast }}
		></span>{/if}
	{@render children?.()}
</span>

<style>
	.tag {
		display: inline-flex;
		height: 1.55rem;
		align-items: center;
		gap: 0.35rem;
		border-radius: 999px;
		padding: 0 0.55rem;
		font-size: 0.72rem;
		font-weight: 600;
		letter-spacing: 0.045em;
		line-height: 1;
		background: var(--color-surface-muted);
		color: var(--color-text-muted);
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, box-shadow;
		transition-timing-function: var(--ease-standard);
	}

	.tag.colored {
		background: color-mix(in srgb, var(--tag-color) 26%, var(--color-surface-solid));
		color: var(--color-text);
	}

	.tag-dot {
		width: 0.5rem;
		height: 0.5rem;
		flex-shrink: 0;
		border-radius: 999px;
		background: var(--tag-color);
	}
</style>
