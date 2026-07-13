<script lang="ts">
	import { Dialog, Popover } from 'bits-ui';
	import { flip } from 'svelte/animate';
	import {
		DURATION,
		motionDialog,
		motionFade,
		motionFlip,
		motionFly,
		motionMenu,
		popRise
	} from '$lib/motion';
	import ArchiveRestoreIcon from 'lucide-svelte/icons/archive-restore';
	import SearchIcon from 'lucide-svelte/icons/search';
	import Trash2Icon from 'lucide-svelte/icons/trash-2';
	import XIcon from 'lucide-svelte/icons/x';
	import {
		cuePadRepository as repo,
		EMPTY_SEARCH_RESULTS,
		type Card,
		type Project,
		type SearchResults
	} from '$lib/db';
	import Button from '$lib/ui/Button.svelte';
	import Mascot from '$lib/ui/Mascot.svelte';
	import { firstContentLine } from '$lib/editor/segments';
	import { formatTime } from './format';
	import { workspace } from './store.svelte';

	let query = $state('');
	let found = $state<SearchResults>(EMPTY_SEARCH_RESULTS);
	let searchSequence = 0;

	// 两击确认删除：第一次点击进入 armed 态（变色），再点执行；移开/超时自动回退
	const ARM_RESET_MS = 2600;
	let armedKey = $state<string | null>(null);
	let armTimer: ReturnType<typeof setTimeout> | undefined;

	function confirmDestroy(key: string, action: () => void) {
		clearTimeout(armTimer);
		if (armedKey === key) {
			armedKey = null;
			action();
			return;
		}
		armedKey = key;
		armTimer = setTimeout(() => (armedKey = null), ARM_RESET_MS);
	}

	let clearOpen = $state(false);
	// 刚清空：空态切成「抸手」姿势，下次打开恢复打盹
	let justEmptied = $state(false);

	$effect(() => {
		if (!workspace.trashOpen) {
			justEmptied = false;
			return;
		}
		query = '';
		workspace.refreshTrash();
	});

	// 回收站内搜索只搜已删内容；依赖 trash 快照，恢复/永删后自动重搜
	$effect(() => {
		void workspace.trash;
		const term = query.trim();
		const sequence = ++searchSequence;
		if (!workspace.trashOpen || !term) {
			found = EMPTY_SEARCH_RESULTS;
			return;
		}
		repo
			.searchContent(term, { deleted: true })
			.then((results) => {
				if (sequence === searchSequence) found = results;
			})
			.catch(() => {
				if (sequence === searchSequence) found = EMPTY_SEARCH_RESULTS;
			});
	});

	const searching = $derived(query.trim().length > 0);

	// 单独删除的卡片才单列；随项目批次删除的卡片归入项目条目；搜索时全部命中卡片平铺
	const soloCards = $derived(workspace.trash.cards.filter((card) => card.deleteSource === 'card'));
	const visibleProjects = $derived(searching ? found.projects : workspace.trash.projects);
	const visibleCards = $derived(searching ? found.cards : soloCards);

	function batchCardCount(batchId: string | null): number {
		if (!batchId) return 0;
		return workspace.trash.cards.filter((card) => card.deleteBatchId === batchId).length;
	}

	function cardLabel(card: Card): string {
		return card.title || firstContentLine(card.body ?? '') || '空白草稿';
	}

	const isEmpty = $derived(visibleProjects.length === 0 && visibleCards.length === 0);
</script>

{#snippet projectRow(project: Project)}
	<div class="trash-row">
		<span class="row-dot" style={`--dot: ${project.color}`}></span>
		<div class="row-text">
			<strong class:unnamed={!project.name}>{project.name ?? '未命名'}</strong>
			<small class="tabular-nums">
				含 {batchCardCount(project.deleteBatchId)} 张卡片 ·
				{formatTime(project.deletedAt ?? project.updatedAt)}
			</small>
		</div>
		<div class="row-actions">
			<button
				type="button"
				class="row-action"
				aria-label="恢复项目"
				title="恢复项目"
				onclick={() => workspace.restoreProject(project.id)}
			>
				<ArchiveRestoreIcon size={14} strokeWidth={2} />
			</button>
			<button
				type="button"
				class="row-action danger"
				class:armed={armedKey === `project-${project.id}`}
				aria-label={armedKey === `project-${project.id}` ? '再点一次永久删除' : '永久删除项目'}
				title={armedKey === `project-${project.id}` ? '再点一次确认' : '永久删除项目'}
				onclick={() =>
					confirmDestroy(`project-${project.id}`, () => workspace.destroyProject(project.id))}
				onmouseleave={() => (armedKey = null)}
			>
				<Trash2Icon size={14} strokeWidth={2} />
			</button>
		</div>
	</div>
{/snippet}

{#snippet cardRow(card: Card)}
	<div class="trash-row">
		<div class="row-text">
			<strong class:unnamed={!card.title && !card.body}>{cardLabel(card)}</strong>
			<small class="tabular-nums">{formatTime(card.deletedAt ?? card.updatedAt)}</small>
		</div>
		<div class="row-actions">
			<button
				type="button"
				class="row-action"
				aria-label="恢复卡片"
				title="恢复卡片"
				onclick={() => workspace.restoreCard(card.id)}
			>
				<ArchiveRestoreIcon size={14} strokeWidth={2} />
			</button>
			<button
				type="button"
				class="row-action danger"
				class:armed={armedKey === `card-${card.id}`}
				aria-label={armedKey === `card-${card.id}` ? '再点一次永久删除' : '永久删除卡片'}
				title={armedKey === `card-${card.id}` ? '再点一次确认' : '永久删除卡片'}
				onclick={() => confirmDestroy(`card-${card.id}`, () => workspace.destroyCard(card.id))}
				onmouseleave={() => (armedKey = null)}
			>
				<Trash2Icon size={14} strokeWidth={2} />
			</button>
		</div>
	</div>
{/snippet}

<Dialog.Root open={workspace.trashOpen} onOpenChange={(next) => (workspace.trashOpen = next)}>
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
					<section {...props} class="trash-card" in:motionDialog out:motionDialog>
						<div class="trash-head">
							<Dialog.Title class="trash-title">回收站</Dialog.Title>
							<div class="head-actions">
								{#if !isEmpty && !searching}
									<Popover.Root bind:open={clearOpen}>
										<Popover.Trigger>
											{#snippet child({ props: popProps })}
												<button {...popProps} type="button" class="clear-trigger">清空</button>
											{/snippet}
										</Popover.Trigger>
										<Popover.Portal>
											<Popover.Content align="end" sideOffset={6} forceMount>
												{#snippet child({ wrapperProps, props: popProps, open })}
													{#if open}
														<div {...wrapperProps}>
															<div {...popProps} class="clear-pop" in:motionMenu out:motionMenu>
																<span>全部永久删除？</span>
																<Button
																	variant="danger"
																	size="sm"
																	onclick={() => {
																		clearOpen = false;
																		void workspace.emptyTrash().then(() => (justEmptied = true));
																	}}
																>
																	清空
																</Button>
															</div>
														</div>
													{/if}
												{/snippet}
											</Popover.Content>
										</Popover.Portal>
									</Popover.Root>
								{/if}
								<Dialog.Close>
									{#snippet child({ props: closeProps })}
										<Button {...closeProps} variant="ghost" size="icon" aria-label="关闭" title="关闭">
											<XIcon size={17} strokeWidth={2} />
										</Button>
									{/snippet}
								</Dialog.Close>
							</div>
						</div>

						<label class="trash-search">
							<SearchIcon size={14} strokeWidth={2} />
							<input
								type="text"
								placeholder="搜索已删除的项目和卡片…"
								aria-label="搜索回收站"
								bind:value={query}
							/>
						</label>

						{#if isEmpty}
							{#key `${searching}:${justEmptied}`}
								<div class="trash-empty" in:popRise={{ y: 8, duration: DURATION.base }}>
									<Mascot
										pose={searching ? 'search' : justEmptied ? 'clean' : 'trash'}
										size={searching ? 84 : 116}
									/>
									<p>
										{searching
											? `回收站里没有匹配「${query.trim()}」的内容`
											: justEmptied
												? '已清空，干干净净'
												: '回收站是空的'}
									</p>
								</div>
							{/key}
						{:else}
							<div class="trash-body">
								{#if visibleProjects.length > 0}
									<p class="ui-label">项目</p>
									{#each visibleProjects as project (project.id)}
										<div
											animate:flip={motionFlip(DURATION.base)}
											in:motionFly|local={{ x: 14 }}
											out:motionFly|local={{ x: 8 }}
										>
											{@render projectRow(project)}
										</div>
									{/each}
								{/if}

								{#if visibleCards.length > 0}
									<p class="ui-label">卡片</p>
									{#each visibleCards as card (card.id)}
										<div
											animate:flip={motionFlip(DURATION.base)}
											in:motionFly|local={{ x: 14 }}
											out:motionFly|local={{ x: 8 }}
										>
											{@render cardRow(card)}
										</div>
									{/each}
								{/if}
							</div>
						{/if}
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

	.trash-card {
		position: fixed;
		left: 50%;
		top: 50%;
		z-index: 80;
		translate: -50% -50%;
		display: grid;
		grid-template-rows: auto auto minmax(0, 1fr);
		width: min(30rem, calc(100vw - 2rem));
		max-height: min(34rem, calc(100dvh - 3rem));
		padding: 1.1rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-panel);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
	}

	.trash-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 0.85rem;
	}

	.head-actions {
		display: flex;
		align-items: center;
		gap: 0.35rem;
	}

	.clear-trigger {
		min-height: 2rem;
		padding: 0 0.8rem;
		border: 0;
		border-radius: 999px;
		background: transparent;
		color: var(--color-text-muted);
		font-size: 0.8rem;
		font-weight: 500;
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard);
	}

	.clear-trigger:hover,
	.clear-trigger[data-state='open'] {
		background: color-mix(in srgb, var(--color-danger) 10%, transparent);
		color: var(--color-danger);
	}

	.clear-pop {
		z-index: 90;
		display: flex;
		align-items: center;
		gap: 0.7rem;
		padding: 0.5rem 0.5rem 0.5rem 0.9rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: 999px;
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		backdrop-filter: blur(18px) saturate(1.05);
		font-size: 0.82rem;
		font-weight: 500;
		color: var(--color-text);
		white-space: nowrap;
	}

	:global(.trash-title) {
		margin: 0;
		font-size: 1.3rem;
		font-weight: 600;
		letter-spacing: -0.04em;
		color: var(--color-text-strong);
	}

	.trash-search {
		display: flex;
		align-items: center;
		gap: 0.55rem;
		margin-bottom: 0.6rem;
		padding: 0 0.75rem;
		min-height: 2.4rem;
		border-radius: var(--radius-control);
		background: var(--color-surface-muted);
		color: var(--color-text-soft);
	}

	.trash-search input {
		flex: 1;
		min-width: 0;
		border: 0;
		padding: 0;
		background: transparent;
		color: var(--color-text-strong);
		font-size: 0.85rem;
	}

	.trash-search input:focus {
		outline: none;
	}

	.trash-empty {
		display: grid;
		justify-items: center;
		gap: 0.9rem;
		margin: 1.2rem 0 1.4rem;
		text-align: center;
		font-size: 0.88rem;
		line-height: 1.65;
		color: var(--color-text-muted);
	}

	.trash-body {
		display: grid;
		align-content: start;
		gap: 0.45rem;
		overflow-y: auto;
		padding-right: 0.2rem;
	}

	.trash-body .ui-label {
		margin: 0.5rem 0 0.1rem;
	}

	.trash-row {
		display: grid;
		grid-template-columns: auto minmax(0, 1fr) auto;
		align-items: center;
		gap: 0.65rem;
		padding: 0.6rem 0.7rem;
		border-radius: var(--radius-card);
		background: var(--color-surface-muted);
	}

	.trash-row:not(:has(.row-dot)) {
		grid-template-columns: minmax(0, 1fr) auto;
	}

	.row-dot {
		width: 0.72rem;
		height: 0.72rem;
		border-radius: 0.28rem;
		background: var(--dot);
		box-shadow: 0 0 0 2.5px color-mix(in srgb, var(--dot) 26%, transparent);
	}

	.row-text {
		display: grid;
		gap: 0.15rem;
	}

	.row-text strong {
		overflow: hidden;
		font-size: 0.86rem;
		font-weight: 600;
		letter-spacing: -0.015em;
		color: var(--color-text-strong);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.row-text strong.unnamed {
		color: var(--color-text-soft);
		font-weight: 500;
	}

	.row-text small {
		font-size: 0.72rem;
		color: var(--color-text-soft);
	}

	.row-actions {
		display: flex;
		gap: 0.3rem;
	}

	.row-action {
		display: grid;
		width: 2.5rem;
		height: 2.5rem;
		place-items: center;
		border: 0;
		border-radius: 0.6rem;
		background: var(--color-surface-solid);
		color: var(--color-text-muted);
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, transform;
		transition-timing-function: var(--ease-standard);
	}

	.row-action:hover {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.row-action:active {
		transform: scale(var(--press-scale));
	}

	.row-action.danger:hover {
		background: color-mix(in srgb, var(--color-danger) 14%, transparent);
		color: var(--color-danger);
	}

	/* 两击确认的 armed 态：实色危险背景 + 脉冲，再点一次执行 */
	.row-action.armed {
		background: var(--color-danger);
		color: #fff8f6;
		animation: fx-arm-pulse 1s var(--ease-standard) infinite;
	}

	.row-action.armed:hover {
		background: var(--color-danger);
		color: #fff8f6;
	}

	/* 减动时关闭脉冲：armed 态实色危险背景本身已足够传达状态 */
	@media (prefers-reduced-motion: reduce) {
		.row-action.armed {
			animation: none;
		}
	}
</style>
