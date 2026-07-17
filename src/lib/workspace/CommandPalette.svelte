<script lang="ts">
	import { DURATION, POP_SCALE, motionFade, motionScale, popRise } from '$lib/motion';
	import FileTextIcon from 'lucide-svelte/icons/file-text';
	import FolderPlusIcon from 'lucide-svelte/icons/folder-plus';
	import PenLineIcon from 'lucide-svelte/icons/pen-line';
	import SearchIcon from 'lucide-svelte/icons/search';
	import SendIcon from 'lucide-svelte/icons/send';
	import SettingsIcon from 'lucide-svelte/icons/settings';
	import Trash2Icon from 'lucide-svelte/icons/trash-2';
	import { cuePadRepository as repo, EMPTY_SEARCH_RESULTS, type Card, type Project, type SearchResults } from '$lib/db';
	import markUrl from '$lib/assets/mark.png';
	import Mascot from '$lib/ui/Mascot.svelte';
	import { firstContentLine, formatSegments } from '$lib/editor/segments';
	import { dispatchAvailable, dispatchPrompt, dispatchTarget } from './dispatch';
	import { editor } from './editor.svelte';
	import { projectIcon } from './palette';
	import { workspace } from './store.svelte';

	type Command = {
		id: string;
		label: string;
		icon: typeof PenLineIcon;
		run: () => void;
	};

	// 固定命令表：不做可扩展注册系统
	const COMMANDS: Command[] = [
		{
			id: 'new-card',
			label: '新建卡片',
			icon: PenLineIcon,
			run: () => void editor.createAndOpen(workspace.activeProjectId)
		},
		{ id: 'new-project', label: '新建项目', icon: FolderPlusIcon, run: () => workspace.openProjectDialog() },
		{ id: 'open-settings', label: '打开设置', icon: SettingsIcon, run: () => (workspace.settingsOpen = true) },
		{ id: 'open-trash', label: '打开回收站', icon: Trash2Icon, run: () => (workspace.trashOpen = true) }
	];

	let query = $state('');
	let results = $state<SearchResults>(EMPTY_SEARCH_RESULTS);
	let activeIndex = $state(-1);
	let listElement = $state<HTMLElement | null>(null);
	let dispatchTargetName = $state<string | null>(null);
	let searchSequence = 0;

	const commands = $derived(
		query.trim() ? COMMANDS.filter((command) => command.label.includes(query.trim())) : COMMANDS
	);
	type PaletteItem =
		| { kind: 'command'; command: Command }
		| { kind: 'project'; project: Project }
		| { kind: 'card'; card: Card };
	const items: PaletteItem[] = $derived([
		...commands.map((command) => ({ kind: 'command', command }) as const),
		...results.projects.map((project) => ({ kind: 'project', project }) as const),
		...results.cards.map((card) => ({ kind: 'card', card }) as const)
	]);

	$effect(() => {
		if (!workspace.paletteOpen) return;
		query = '';
		results = EMPTY_SEARCH_RESULTS;
		activeIndex = -1;
		if (dispatchAvailable) {
			void dispatchTarget().then((target) => (dispatchTargetName = target?.name ?? null));
		}
	});

	$effect(() => {
		const term = query.trim();
		if (!workspace.paletteOpen) return;
		const sequence = ++searchSequence;
		if (!term) {
			results = EMPTY_SEARCH_RESULTS;
			return;
		}
		repo
			.searchContent(term)
			.then((found) => {
				if (sequence !== searchSequence) return;
				results = found;
				activeIndex = -1;
			})
			.catch(() => {
				if (sequence === searchSequence) results = EMPTY_SEARCH_RESULTS;
			});
	});

	$effect(() => {
		if (!listElement) return;
		listElement
			.querySelector(`[data-index="${activeIndex}"]`)
			?.scrollIntoView({ block: 'nearest' });
	});

	function close() {
		workspace.paletteOpen = false;
	}

	function execute(item: PaletteItem | undefined) {
		if (!item) return;
		close();
		if (item.kind === 'command') item.command.run();
		if (item.kind === 'project') workspace.selectProject(item.project.id);
		if (item.kind === 'card') {
			workspace.selectProject(item.card.projectId);
			void editor.open(item.card.id);
		}
	}

	// window 级处理 Escape：焦点不在输入框时也能关闭；本组件常驻挂载，
	// listener 先于条件渲染的 FocusEditor 注册，preventDefault 后它会跳过退出沉浸
	function onWindowKeydown(event: KeyboardEvent) {
		if (!workspace.paletteOpen || event.key !== 'Escape') return;
		event.preventDefault();
		close();
	}

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
			event.preventDefault();
			if (items.length === 0) return;
			if (event.key === 'ArrowDown') activeIndex = (activeIndex + 1) % items.length;
			else activeIndex = activeIndex < 0 ? items.length - 1 : (activeIndex - 1 + items.length) % items.length;
			return;
		}
		if (event.key === 'Enter') {
			event.preventDefault();
			execute(items[activeIndex]);
		}
	}

	function autofocus(node: HTMLInputElement) {
		node.focus();
	}

	function cardLabel(card: Card): string {
		return card.title || firstContentLine(card.body ?? '') || '空白草稿';
	}

	function cardProjectName(card: Card): string {
		if (card.projectId === null) return '未归档';
		return workspace.projects.find((project) => project.id === card.projectId)?.name ?? '未命名';
	}

	function dispatchCard(card: Card) {
		close();
		// 正在沉浸编辑的卡：权威正文/编号是 editor 草稿（异步落库期间 DB 是旧值）
		const editing = editor.cardId === card.id;
		const body = editing ? editor.body : (card.body ?? '');
		const numbering = editing ? editor.numbering : card.numbering;
		void dispatchPrompt({
			text: formatSegments(body, numbering),
			cardId: card.id,
			label: '卡片'
		});
	}
</script>

<svelte:window onkeydown={onWindowKeydown} />

{#if workspace.paletteOpen}
	<div class="palette-layer">
		<button
			type="button"
			class="palette-backdrop"
			aria-label="关闭命令面板"
			onclick={close}
			in:motionFade
			out:motionFade
		></button>
		<div
			class="palette"
			role="dialog"
			aria-label="命令面板"
			in:motionScale={POP_SCALE}
			out:motionScale={POP_SCALE}
		>
			<div class="palette-input-row">
				<SearchIcon size={16} strokeWidth={2} />
				<input
					type="text"
					placeholder="搜索项目/卡片/标签/命令..."
					aria-label="搜索"
					bind:value={query}
					onkeydown={onKeydown}
					use:autofocus
				/>
			</div>

			<div class="palette-results" bind:this={listElement}>
				{#if items.length === 0}
					<div class="palette-empty" in:popRise={{ y: 6, duration: DURATION.base }}>
						<Mascot pose="search" size={84} />
						<p>没有匹配「{query.trim()}」的内容</p>
					</div>
				{:else}
					{#if commands.length > 0}
						{#each commands as command, offset (command.id)}
							{@const index = offset}
							{@const Icon = command.icon}
							<button
								type="button"
								class="palette-item"
								class:active={activeIndex === index}
								data-index={index}
								onmouseenter={() => (activeIndex = index)}
								onclick={() => execute(items[index])}
							>
								<span class="item-glyph"><Icon size={14} strokeWidth={2} /></span>
								<span class="item-title">{command.label}</span>
							</button>
						{/each}
					{/if}

					{#if results.projects.length > 0}
						<p class="ui-label">项目</p>
						{#each results.projects as project, offset (project.id)}
							{@const index = commands.length + offset}
							{@const Icon = projectIcon(project.icon)}
							<button
								type="button"
								class="palette-item"
								class:active={activeIndex === index}
								data-index={index}
								onmouseenter={() => (activeIndex = index)}
								onclick={() => execute(items[index])}
							>
								<span class="item-glyph project glyph-sheen" style={`--project-color: ${project.color}`}>
									{#if Icon}<Icon size={13} strokeWidth={2.4} />{/if}
								</span>
								<span class="item-title" class:unnamed={!project.name}>{project.name ?? '未命名'}</span>
							</button>
						{/each}
					{/if}

					{#if results.cards.length > 0}
						<p class="ui-label">卡片</p>
						{#each results.cards as card, offset (card.id)}
							{@const index = commands.length + results.projects.length + offset}
							<div
								class="card-result"
								class:active={activeIndex === index}
								data-index={index}
							>
								<button
									type="button"
									class="palette-item"
									onmouseenter={() => (activeIndex = index)}
									onclick={() => execute(items[index])}
								>
									<span class="item-glyph"><FileTextIcon size={14} strokeWidth={2} /></span>
									<span class="item-title" class:unnamed={!card.title && !card.body}>{cardLabel(card)}</span>
									<span class="item-hint">{cardProjectName(card)}</span>
								</button>
								{#if dispatchAvailable && dispatchTargetName}
									<button
										type="button"
										class="item-dispatch"
										aria-label={`投送 ${cardLabel(card)} 到 ${dispatchTargetName}`}
										title={`投送到 ${dispatchTargetName}`}
										onmouseenter={() => (activeIndex = index)}
										onclick={() => dispatchCard(card)}
									>
										<SendIcon size={14} strokeWidth={2} />
									</button>
								{/if}
							</div>
						{/each}
					{/if}
				{/if}
			</div>

			<div class="palette-foot" aria-hidden="true">
				<span class="foot-mark" style="--mark: url({markUrl})"></span>
				<span class="foot-hints">
					<span class="hint"><kbd class="ui-kbd">↑↓</kbd>选择</span>
					<span class="hint"><kbd class="ui-kbd">⏎</kbd>打开</span>
				</span>
			</div>
		</div>
	</div>
{/if}

<style>
	.palette-layer {
		position: fixed;
		inset: 0;
		z-index: 90;
		display: grid;
		justify-items: center;
		align-content: start;
		padding-top: 16vh;
	}

	.palette-backdrop {
		position: absolute;
		inset: 0;
		border: 0;
		padding: 0;
		background: rgba(15, 17, 16, 0.3);
		backdrop-filter: blur(6px);
	}

	.palette {
		position: relative;
		display: grid;
		grid-template-rows: auto minmax(0, 1fr) auto;
		width: min(37rem, calc(100vw - 2rem));
		max-height: min(24rem, calc(100dvh - 20vh - 2rem));
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-panel);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		backdrop-filter: blur(20px) saturate(1.05);
		overflow: hidden;
	}

	.palette-input-row {
		display: flex;
		align-items: center;
		gap: 0.65rem;
		padding: 0.95rem 1.1rem;
		border-bottom: 1px solid var(--color-border-subtle);
		color: var(--color-text-soft);
	}

	.palette-input-row input {
		flex: 1;
		min-width: 0;
		border: 0;
		padding: 0;
		background: transparent;
		color: var(--color-text-strong);
		font-size: 0.98rem;
	}

	.palette-input-row input:focus {
		outline: none;
	}

	.palette-input-row input::placeholder {
		color: var(--color-text-soft);
	}

	.palette-results {
		display: grid;
		align-content: start;
		gap: 0.15rem;
		overflow-y: auto;
		padding: 0.55rem;
	}

	.palette-results .ui-label {
		margin: 0.45rem 0.55rem 0.2rem;
	}

	.palette-foot {
		display: flex;
		align-items: center;
		padding: 0.45rem 0.9rem 0.5rem;
		font-size: 0.72rem;
		color: var(--color-text-soft);
		user-select: none;
	}

	.foot-mark {
		width: 1.25rem;
		height: 1rem;
		background: currentColor;
		-webkit-mask: var(--mark) center / contain no-repeat;
		mask: var(--mark) center / contain no-repeat;
		opacity: 0.6;
	}

	.foot-hints {
		display: inline-flex;
		align-items: center;
		gap: 0.9rem;
		margin-left: auto;
	}

	.foot-hints .hint {
		display: inline-flex;
		align-items: center;
		gap: 0.35rem;
	}


	.palette-empty {
		display: grid;
		justify-items: center;
		gap: 0.75rem;
		margin: 1.1rem 0.55rem 1.2rem;
		text-align: center;
		font-size: 0.86rem;
		color: var(--color-text-muted);
	}

	.card-result {
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		align-items: center;
		border-radius: 0.8rem;
	}

	.card-result.active {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.palette-item {
		display: grid;
		grid-template-columns: auto minmax(0, 1fr) auto;
		align-items: center;
		gap: 0.6rem;
		min-height: 2.5rem;
		padding: 0 0.65rem;
		border: 0;
		border-radius: 0.8rem;
		background: transparent;
		color: var(--color-text);
		text-align: left;
	}

	.palette-item.active {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.card-result .palette-item {
		min-width: 0;
		color: inherit;
	}

	.item-dispatch {
		display: grid;
		width: 2rem;
		height: 2rem;
		margin-right: 0.3rem;
		place-items: center;
		border: 0;
		border-radius: 0.65rem;
		background: transparent;
		color: var(--color-text-soft);
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard),
			transform var(--duration-fast) var(--ease-standard);
	}

	.item-dispatch:hover {
		background: var(--color-surface-solid);
		color: var(--color-accent-text);
	}

	.item-dispatch:active {
		transform: scale(var(--press-scale));
	}

	.item-glyph {
		display: inline-grid;
		width: 1.5rem;
		height: 1.5rem;
		place-items: center;
		border-radius: 0.5rem;
		background: var(--color-surface-muted);
		color: var(--color-text-muted);
	}

	.item-glyph.project {
		background: var(--project-color);
		color: rgba(20, 24, 21, 0.72);
	}

	.item-title {
		overflow: hidden;
		font-size: 0.88rem;
		font-weight: 500;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.item-title.unnamed {
		color: var(--color-text-soft);
	}

	.item-hint {
		overflow: hidden;
		max-width: 9rem;
		font-size: 0.74rem;
		color: var(--color-text-soft);
		text-overflow: ellipsis;
		white-space: nowrap;
	}
</style>
