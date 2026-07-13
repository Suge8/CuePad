<script lang="ts">
	import { PROJECT_COLORS, PROJECT_ICON_KEYS, projectIcon } from '$lib/workspace/palette';

	type Props = {
		selectedColor: string;
		selectedIcon: string | null;
		onColorChange: (color: string) => void;
		onIconChange: (icon: string | null) => void;
	};

	let { selectedColor, selectedIcon, onColorChange, onIconChange }: Props = $props();
</script>

<div class="picker">
	<div class="swatches" role="group" aria-label="项目颜色">
		{#each PROJECT_COLORS as color (color.value)}
			<button
				type="button"
				class="swatch"
				class:active={selectedColor === color.value}
				style={`--swatch: ${color.value}`}
				aria-label={`使用 ${color.name}`}
				aria-pressed={selectedColor === color.value}
				onclick={() => selectedColor !== color.value && onColorChange(color.value)}
			></button>
		{/each}
	</div>

	<div class="icon-grid" role="group" aria-label="项目图标">
		<button
			type="button"
			class:active={selectedIcon === null}
			aria-pressed={selectedIcon === null}
			aria-label="无图标"
			onclick={() => selectedIcon !== null && onIconChange(null)}
		>
			<span class="none-mark">—</span>
		</button>
		{#each PROJECT_ICON_KEYS as key (key)}
			{@const Icon = projectIcon(key)}
			<button
				type="button"
				class:active={selectedIcon === key}
				aria-pressed={selectedIcon === key}
				aria-label={`图标 ${key}`}
				onclick={() => selectedIcon !== key && onIconChange(key)}
			>
				<Icon size={15} strokeWidth={2} />
			</button>
		{/each}
	</div>
</div>

<style>
	.picker {
		display: grid;
		min-width: 0;
		gap: 0.85rem;
	}

	.swatches {
		display: grid;
		grid-template-columns: repeat(5, 2.5rem);
		justify-content: space-between;
		gap: 0.3rem;
	}

	.swatch {
		position: relative;
		width: 2.5rem;
		height: 2.5rem;
		border: 0;
		border-radius: 999px;
		background: transparent;
		transition:
			transform var(--duration-base) var(--ease-spring),
			box-shadow var(--duration-fast) var(--ease-standard);
	}

	.swatch::before {
		position: absolute;
		inset: 0.42rem;
		border-radius: inherit;
		background: var(--swatch);
		box-shadow: 0 1px 2px rgba(20, 16, 10, 0.12);
		content: '';
	}

	.swatch:hover {
		transform: scale(var(--hover-pop));
	}

	.swatch:active {
		transform: scale(var(--press-scale));
	}

	.swatch.active::before {
		box-shadow:
			0 0 0 2px var(--color-surface-raised),
			0 0 0 3.5px var(--swatch);
	}

	.icon-grid {
		display: grid;
		gap: 0.3rem;
		grid-template-columns: repeat(8, minmax(0, 1fr));
	}

	.icon-grid button {
		display: grid;
		height: 2.5rem;
		place-items: center;
		border: 0;
		border-radius: 0.7rem;
		background: var(--color-surface-solid);
		color: var(--color-text-muted);
		transition-duration: var(--duration-fast);
		transition-property: transform, background-color, color, box-shadow;
		transition-timing-function: var(--ease-standard);
	}

	.icon-grid button:hover {
		background: var(--color-surface-muted);
		color: var(--color-text-strong);
	}

	.icon-grid button:active {
		transform: scale(var(--press-scale));
	}

	.icon-grid button.active {
		background: color-mix(in srgb, var(--color-text-strong) 88%, transparent);
		color: var(--color-canvas-soft);
	}

	.none-mark {
		font-size: 0.8rem;
		color: currentColor;
	}
</style>
