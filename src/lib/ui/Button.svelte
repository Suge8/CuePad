<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { HTMLButtonAttributes } from 'svelte/elements';
	type Variant = 'primary' | 'secondary' | 'ghost' | 'danger';
	type Size = 'sm' | 'md' | 'icon';
	type Props = HTMLButtonAttributes & {
		variant?: Variant;
		size?: Size;
		children?: Snippet;
	};

	let {
		variant = 'secondary',
		size = 'md',
		type = 'button',
		children,
		class: className = '',
		...rest
	}: Props = $props();
</script>

<button {...rest} {type} class={`ui-button ${variant} ${size} ${className}`}>
	{@render children?.()}
</button>

<style>
	.ui-button {
		display: inline-flex;
		min-width: max-content;
		align-items: center;
		justify-content: center;
		gap: 0.5rem;
		border: 0;
		border-radius: var(--radius-control);
		cursor: pointer;
		user-select: none;
		font-weight: 600;
		line-height: 1;
		transition-duration: var(--duration-base);
		transition-property: transform, background-color, color, box-shadow, opacity;
		transition-timing-function: var(--ease-standard);
		-webkit-tap-highlight-color: transparent;
	}

	.ui-button:disabled {
		cursor: not-allowed;
		opacity: 0.48;
	}

	.ui-button:not(:disabled):active {
		transform: scale(var(--press-scale));
	}

	.md {
		min-height: 2.5rem;
		padding: 0 0.9rem;
		font-size: 0.86rem;
	}

	.sm {
		min-height: 2.25rem;
		padding: 0 0.75rem;
		border-radius: 0.75rem;
		font-size: 0.8rem;
	}

	.icon {
		width: 2.5rem;
		height: 2.5rem;
		padding: 0;
		font-size: 0.92rem;
	}

	.primary {
		background: var(--color-accent-strong);
		color: var(--color-accent-contrast);
		box-shadow: var(--shadow-control);
	}

	.primary:not(:disabled):hover {
		background: color-mix(in srgb, var(--color-accent-strong) 88%, var(--color-text-strong));
	}

	.secondary {
		background: var(--color-surface-solid);
		color: var(--color-text);
		box-shadow: var(--shadow-control);
	}

	.secondary:not(:disabled):hover,
	.ghost:not(:disabled):hover {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.ghost {
		background: transparent;
		color: var(--color-text-muted);
		box-shadow: none;
	}

	.danger {
		background: color-mix(in srgb, var(--color-danger) 12%, var(--color-surface-solid));
		color: var(--color-danger);
		box-shadow: none;
	}

	.danger:not(:disabled):hover {
		background: color-mix(in srgb, var(--color-danger) 18%, var(--color-surface-solid));
	}
</style>
