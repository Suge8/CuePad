<script lang="ts">
	import CheckIcon from 'lucide-svelte/icons/check';
	import CircleAlertIcon from 'lucide-svelte/icons/circle-alert';
	import CopyIcon from 'lucide-svelte/icons/copy';
	import Trash2Icon from 'lucide-svelte/icons/trash-2';
	import Undo2Icon from 'lucide-svelte/icons/undo-2';
	import { motionFade, motionFly } from '$lib/motion';
	import type { ToastIcon, ToastTone } from '$lib/workspace/store.svelte';
	import Sparkle from './Sparkle.svelte';

	type Props = {
		visible: boolean;
		message: string;
		detail?: string;
		tone?: ToastTone;
		icon?: ToastIcon;
	};

	let { visible, message, detail = '', tone = 'neutral', icon = 'check' }: Props = $props();

	const ICONS = {
		copy: CopyIcon,
		trash: Trash2Icon,
		restore: Undo2Icon,
		check: CheckIcon,
		error: CircleAlertIcon
	} as const;
	const Icon = $derived(ICONS[icon]);
</script>

{#if visible}
	<div
		class={`toast ${tone}`}
		role="status"
		aria-live="polite"
		in:motionFly={{ y: -8 }}
		out:motionFade
	>
		<span class="toast-icon" aria-hidden="true">
			{#if tone === 'success'}
				<!-- 成功态：品牌四角星 + 一次性星尘迸发 -->
				<Sparkle size={13} />
				<i class="spark" style="--dx: -13px; --dy: -9px"></i>
				<i class="spark" style="--dx: 13px; --dy: -11px; animation-delay: 160ms"></i>
				<i class="spark" style="--dx: -10px; --dy: 11px; animation-delay: 200ms"></i>
				<i class="spark" style="--dx: 12px; --dy: 9px; animation-delay: 130ms"></i>
			{:else}
				<Icon size={14} strokeWidth={2.2} />
			{/if}
		</span>
		<div class="toast-text">
			<strong>{message}</strong>
			{#if detail}
				<p>{detail}</p>
			{/if}
		</div>
	</div>
{/if}

<style>
	.toast {
		position: fixed;
		top: 1.25rem;
		right: 1.25rem;
		z-index: 80;
		display: flex;
		align-items: center;
		max-width: min(22rem, calc(100vw - 2.5rem));
		gap: 0.6rem;
		padding: 0.55rem 0.9rem 0.55rem 0.6rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: 999px;
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		backdrop-filter: blur(18px) saturate(1.05);
	}

	/* 带错误详情时回到卡片形态 */
	.toast:has(p) {
		align-items: start;
		border-radius: var(--radius-card);
	}

	.toast-icon {
		position: relative;
		display: grid;
		width: 1.75rem;
		height: 1.75rem;
		flex-shrink: 0;
		place-items: center;
		border-radius: 999px;
		background: var(--color-surface-muted);
		color: var(--color-text-muted);
		animation: fx-icon-pop var(--duration-base) var(--ease-standard) both;
		animation-delay: 60ms;
	}

	/* 星尘：从图标中心飞散的小星点，播一次即消失 */
	.spark {
		position: absolute;
		top: 50%;
		left: 50%;
		width: 4px;
		height: 4px;
		margin: -2px 0 0 -2px;
		border-radius: 999px;
		background: currentColor;
		opacity: 0;
		animation: fx-spark-fly 560ms var(--ease-standard) 120ms both;
	}

	@media (prefers-reduced-motion: reduce) {
		.spark,
		.toast-icon {
			animation: none;
		}
	}

	.success .toast-icon {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.danger .toast-icon {
		background: color-mix(in srgb, var(--color-danger) 14%, transparent);
		color: var(--color-danger);
	}

	.toast-text {
		min-width: 0;
	}

	strong {
		display: block;
		font-size: 0.85rem;
		font-weight: 600;
		letter-spacing: -0.015em;
		line-height: 1.3;
		color: var(--color-text-strong);
	}

	p {
		margin: 0.2rem 0 0;
		font-size: 0.76rem;
		line-height: 1.5;
		color: var(--color-text-muted);
	}
</style>
