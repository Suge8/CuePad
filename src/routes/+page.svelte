<script lang="ts">
	import {
		DURATION,
		motionFade,
		motionIconSwitch,
		motionScale,
		overlayEnter,
		popRise
	} from '$lib/motion';
	import { listen } from '@tauri-apps/api/event';
	import SearchIcon from 'lucide-svelte/icons/search';
	import SettingsIcon from 'lucide-svelte/icons/settings';
	import StarIcon from 'lucide-svelte/icons/star';
	import markUrl from '$lib/assets/mark.png';
	import Mascot from '$lib/ui/Mascot.svelte';
	import Sparkle from '$lib/ui/Sparkle.svelte';
	import Toast from '$lib/ui/Toast.svelte';
	import CardBoard from '$lib/workspace/CardBoard.svelte';
	import CommandPalette from '$lib/workspace/CommandPalette.svelte';
	import FocusEditor from '$lib/workspace/FocusEditor.svelte';
	import ProjectDialog from '$lib/workspace/ProjectDialog.svelte';
	import SettingsDialog from '$lib/workspace/SettingsDialog.svelte';
	import TaskStack from '$lib/workspace/TaskStack.svelte';
	import TrashDialog from '$lib/workspace/TrashDialog.svelte';
	import VariableFillDialog from '$lib/workspace/VariableFillDialog.svelte';
	import WelcomeCard from '$lib/workspace/WelcomeCard.svelte';
	import { editor } from '$lib/workspace/editor.svelte';
	import { workspace } from '$lib/workspace/store.svelte';
	import './page.css';

	$effect(() => {
		workspace.init();
	});

	// 托盘菜单「设置」→ Rust 侧 emit → 打开设置页
	$effect(() => {
		const unlisten = listen('cuepad://open-settings', () => {
			workspace.settingsOpen = true;
		});
		return () => {
			unlisten.then((stop) => stop());
		};
	});

	// capture 阶段拦截，任意焦点（含 CodeMirror）下都先于编辑器和浏览器默认查找；
	// 设置页快捷键录制中的按键不拦截，交给录制按钮自己处理
	function onGlobalKeydown(event: KeyboardEvent) {
		if (event.target instanceof Element && event.target.closest('[data-shortcut-recorder]')) return;
		if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && event.code === 'KeyF') {
			event.preventDefault();
			event.stopPropagation();
			workspace.paletteOpen = !workspace.paletteOpen;
		}
	}
</script>

<svelte:window onkeydowncapture={onGlobalKeydown} />

<svelte:head>
	<title>CuePad</title>
</svelte:head>

<main class="app-shell">
	<Toast
		visible={workspace.toast.visible}
		message={workspace.toast.message}
		detail={workspace.toast.detail}
		tone={workspace.toast.tone}
		icon={workspace.toast.icon}
	/>

	<header class="topbar" data-tauri-drag-region>
		<span class="brandmark" role="img" aria-label="CuePad" style="--mark: url({markUrl})"></span>

		<button type="button" class="searchbar" onclick={() => (workspace.paletteOpen = true)}>
			<SearchIcon size={15} strokeWidth={2} />
			<span class="search-hint">搜索</span>
			<kbd class="ui-kbd">⌘F</kbd>
		</button>

		<div class="topbar-actions">
			{#if workspace.ready && !editor.isOpen}
				<TaskStack />
			{/if}
			{#if !workspace.isEmptyWorkspace}
				<button
					type="button"
					class="top-action"
					class:active={workspace.showingFavorites}
					data-favorites-trigger
					data-icon-switch
					data-state={workspace.showingFavorites ? 'active' : 'idle'}
					aria-label="全局收藏"
					aria-pressed={workspace.showingFavorites}
					title="全局收藏"
					use:motionIconSwitch={workspace.showingFavorites}
					in:motionScale={{ start: 0.6, duration: DURATION.base }}
					out:motionScale={{ start: 0.8, duration: DURATION.fast }}
					onclick={() => workspace.toggleFavoritesView()}
				>
					<span class="fx-icon-switch" aria-hidden="true">
						<StarIcon class="fx-icon-off" size={16} strokeWidth={2} />
						<StarIcon class="fx-icon-on" size={16} strokeWidth={2} fill="currentColor" />
					</span>
				</button>
			{/if}
			<button
				type="button"
				class="top-action"
				data-settings-trigger
				aria-label="设置"
				title="设置"
				onclick={() => (workspace.settingsOpen = true)}
			>
				<SettingsIcon size={16} strokeWidth={2} />
			</button>
		</div>
	</header>

	{#if workspace.ready}
		{#if workspace.isEmptyWorkspace}
			<div class="hero" in:motionFade out:motionFade>
				<!-- 背景点缀：品牌图形语言的线稿散落，只在空态出现 -->
				<div class="hero-doodles" aria-hidden="true">
					<span class="doodle d1"><Sparkle size={20} /></span>
					<span class="doodle d2"><Sparkle size={12} /></span>
					<span class="doodle d3">{'{ }'}</span>
					<span class="doodle d4">
						<svg width="44" height="38" viewBox="0 0 44 38" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
							<path d="M8 3h20l10 10v16a6 6 0 0 1-6 6H8a6 6 0 0 1-6-6V9a6 6 0 0 1 6-6Z" />
							<path d="M28 3v10h10" />
							<path d="M10 20h16M10 27h10" />
						</svg>
					</span>
					<span class="doodle d5"><Sparkle size={9} /></span>
				</div>
				<div class="hero-ip" in:popRise={{ y: 14 }}>
					<Mascot pose="empty" size={168} />
				</div>
				<button
					type="button"
					class="hero-start"
					in:popRise={{ delay: 70, duration: DURATION.base }}
					onclick={() => editor.createAndOpen()}
				>
					记录灵感
				</button>
			</div>
		{:else}
			<div class="board-scroll" in:motionFade>
				<CardBoard />
			</div>
		{/if}
	{:else if workspace.loadError}
		<div class="hero" in:motionFade out:motionFade>
			<div in:popRise={{ y: 14 }}>
				<Mascot pose="error" size={150} />
			</div>
			<p class="hero-error">加载失败：{workspace.loadError}</p>
			<button type="button" class="hero-start" onclick={() => workspace.init()}>重试</button>
		</div>
	{/if}

	{#if editor.isOpen}
		<div
			class="focus-overlay"
			in:overlayEnter
			out:motionScale={{ start: 0.985, duration: DURATION.overlay }}
		>
			<FocusEditor />
		</div>
	{/if}

	<CommandPalette />
	<VariableFillDialog />
	<WelcomeCard />
	<SettingsDialog />
	<TrashDialog />
	<ProjectDialog
		open={workspace.projectDialog.open}
		project={workspace.projectDialog.project}
		onClose={() => workspace.closeProjectDialog()}
	/>
</main>
