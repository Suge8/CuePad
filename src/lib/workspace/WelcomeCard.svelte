<script lang="ts">
	import { motionFade, popRise } from '$lib/motion';
	import { formatAccelerator } from '$lib/shell/accelerator';
	import Button from '$lib/ui/Button.svelte';
	import Mascot from '$lib/ui/Mascot.svelte';
	import { workspace } from './store.svelte';

	const WELCOMED_KEY = 'cuepad:welcomed';

	let open = $state(false);

	$effect(() => {
		if (workspace.ready && !localStorage.getItem(WELCOMED_KEY)) open = true;
	});

	function close() {
		localStorage.setItem(WELCOMED_KEY, '1');
		open = false;
	}
</script>

{#if open}
	<div class="welcome-overlay" in:motionFade out:motionFade></div>
	<div class="welcome-card" role="dialog" aria-label="欢迎" in:popRise={{ y: 16 }} out:popRise={{ y: 16 }}>
		<Mascot pose="welcome" size={148} />
		<h2>欢迎使用 CuePad</h2>
		<p class="welcome-sub">给 Vibe Coding 设计的灵感本</p>
		<ul class="welcome-hints">
			<li>
				<kbd class="ui-kbd">{formatAccelerator(workspace.globalShortcut).replace(' ', ' + ')}</kbd>
				<span>随时唤出 / 隐藏窗口</span>
			</li>
			<li>
				<kbd class="ui-kbd">⌘ + F</kbd>
				<span>搜索卡片 / 命令</span>
			</li>
			<li>
				<kbd class="ui-kbd">⇧ + Enter</kbd>
				<span>分块书写，逐块复制发送</span>
			</li>
		</ul>
		<Button variant="primary" onclick={close}>开始使用</Button>
	</div>
{/if}

<style>
	.welcome-overlay {
		position: fixed;
		inset: 0;
		z-index: 90;
		background: rgba(15, 17, 16, 0.34);
		backdrop-filter: blur(8px);
	}

	.welcome-card {
		position: fixed;
		left: 50%;
		top: 50%;
		z-index: 91;
		translate: -50% -50%;
		display: grid;
		justify-items: center;
		gap: 0.55rem;
		width: min(22.5rem, calc(100vw - 2rem));
		padding: 2rem 1.8rem 1.6rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-panel);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		text-align: center;
	}

	h2 {
		margin: 0.9rem 0 0;
		font-size: 1.25rem;
		font-weight: 650;
		letter-spacing: -0.03em;
		color: var(--color-text-strong);
	}

	.welcome-sub {
		margin: 0;
		font-size: 0.82rem;
		color: var(--color-text-muted);
	}

	.welcome-hints {
		display: grid;
		gap: 0.45rem;
		width: 100%;
		margin: 0.9rem 0 1.1rem;
		padding: 0;
		list-style: none;
	}

	.welcome-hints li {
		display: flex;
		align-items: center;
		gap: 0.7rem;
		padding: 0.5rem 0.7rem;
		border-radius: var(--radius-card);
		background: var(--color-surface-muted);
		font-size: 0.8rem;
		color: var(--color-text-muted);
		text-align: left;
	}

	/* 行内已有底色，kbd 只靠颜色与等宽区分，不再套盒 */
	.welcome-hints kbd {
		flex-shrink: 0;
		color: var(--color-text-strong);
	}
</style>
