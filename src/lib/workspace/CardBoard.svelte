<script lang="ts">
	import { Popover } from 'bits-ui';
	import { draggable, droppable, type DragDropState } from '@thisux/sveltednd';
	import { flip } from 'svelte/animate';
	import {
		DURATION,
		EASE_SPRING,
		STAGGER_MS,
		motionFade,
		motionFlip,
		motionFly,
		motionIconSwitch,
		motionMenu,
		motionScale,
		popRise,
		staggerDelay
	} from '$lib/motion';
	import EllipsisIcon from 'lucide-svelte/icons/ellipsis';
	import FolderPlusIcon from 'lucide-svelte/icons/folder-plus';
	import InboxIcon from 'lucide-svelte/icons/inbox';
	import PencilIcon from 'lucide-svelte/icons/pencil';
	import PinIcon from 'lucide-svelte/icons/pin';
	import PinOffIcon from 'lucide-svelte/icons/pin-off';
	import PlusIcon from 'lucide-svelte/icons/plus';
	import StarIcon from 'lucide-svelte/icons/star';
	import Trash2Icon from 'lucide-svelte/icons/trash-2';
	import type { Card, Project } from '$lib/db';
	import { firstContentLine } from '$lib/editor/segments';
	import Mascot from '$lib/ui/Mascot.svelte';
	import { editor } from './editor.svelte';
	import { formatTime } from './format';
	import { paletteForeground, projectIcon } from './palette';
	import { mergePartitionOrder, reorderIds, stablePartition } from './reorder';
	import { workspace } from './store.svelte';
	import { orderedProjects } from './view';

	let projectMenuId = $state<number | null>(null);

	const baseProjects: Project[] = $derived.by(() =>
		[...workspace.projects].sort(
			(left, right) => left.sortOrder - right.sortOrder || left.id - right.id
		)
	);
	const navProjects: Project[] = $derived(orderedProjects(workspace.projects));
	const projectsById: Record<number, Project> = $derived.by(
		() => Object.fromEntries(workspace.projects.map((project) => [project.id, project]))
	);
	const activeProject = $derived(
		workspace.activeProjectId === null ? null : (projectsById[workspace.activeProjectId] ?? null)
	);
	const baseCards: Card[] = $derived.by(() =>
		workspace.cards
			.filter((card) => card.projectId === workspace.activeProjectId)
			.sort((left, right) => left.sortOrder - right.sortOrder || left.id - right.id)
	);
	const visibleCards: Card[] = $derived.by(() => {
		if (workspace.showingFavorites) {
			return workspace.cards
				.filter((card) => card.isFavorite)
				.sort((left, right) => right.updatedAt - left.updatedAt || right.id - left.id);
		}
		return stablePartition(baseCards, (card) => card.isFavorite);
	});
	const viewTitle = $derived(
		workspace.showingFavorites
			? '全局收藏'
			: activeProject
				? (activeProject.name ?? '未命名')
				: '未归档'
	);
	const cardViewKey = $derived(
		workspace.showingFavorites ? 'favorites' : `project:${workspace.activeProjectId ?? 'inbox'}`
	);

	function preview(card: Card): string {
		return firstContentLine(card.body ?? '');
	}

	function openCard(card: Card) {
		workspace.selectProject(card.projectId);
		void editor.open(card.id);
	}

	function onProjectWheel(event: WheelEvent) {
		if (Math.abs(event.deltaX) >= Math.abs(event.deltaY) || event.deltaY === 0) return;
		const projectBar = event.currentTarget as HTMLElement;
		const maxScroll = projectBar.scrollWidth - projectBar.clientWidth;
		if (maxScroll <= 0) return;
		const nextScroll = Math.max(0, Math.min(maxScroll, projectBar.scrollLeft + event.deltaY));
		if (nextScroll === projectBar.scrollLeft) return;
		event.preventDefault();
		projectBar.scrollLeft = nextScroll;
	}

	function onProjectDrop(state: DragDropState<Project>, target: Project) {
		const partition = baseProjects.filter((project) => project.isPinned === target.isPinned);
		const orderedPartition = reorderIds(
			partition,
			state.draggedItem.id,
			target.id,
			state.dropPosition
		);
		if (!orderedPartition) return;
		const ordered = mergePartitionOrder(
			baseProjects,
			orderedPartition,
			(project) => project.isPinned === target.isPinned
		);
		if (ordered) void workspace.reorderProjects(ordered);
	}

	function onCardDrop(state: DragDropState<Card>, target: Card) {
		if (workspace.showingFavorites) return;
		const partition = baseCards.filter((card) => card.isFavorite === target.isFavorite);
		const orderedPartition = reorderIds(
			partition,
			state.draggedItem.id,
			target.id,
			state.dropPosition
		);
		if (!orderedPartition) return;
		const ordered = mergePartitionOrder(
			baseCards,
			orderedPartition,
			(card) => card.isFavorite === target.isFavorite
		);
		if (ordered) void workspace.reorderCards(ordered);
	}
</script>

<div class="board">
	<nav class="project-bar" aria-label="项目" onwheel={onProjectWheel}>
		<div class="project-strip">
			<div class="project-item inbox" class:selected={!workspace.showingFavorites && workspace.activeProjectId === null}>
				<button
					type="button"
					class="project-select"
					aria-current={!workspace.showingFavorites && workspace.activeProjectId === null ? 'page' : undefined}
					onclick={() => workspace.selectProject(null)}
				>
					<span class="project-glyph inbox"><InboxIcon size={16} strokeWidth={2.1} /></span>
					<span class="project-copy"><strong>未归档</strong></span>
				</button>
			</div>

			{#each navProjects as project, projectIndex (project.id)}
				{@const Icon = projectIcon(project.icon)}
				<div
					class="project-item"
					class:pinned={project.isPinned}
					class:selected={!workspace.showingFavorites && workspace.activeProjectId === project.id}
					data-project-actions
					data-project-id={project.id}
					style={`--project-color: ${project.color}`}
					animate:flip={motionFlip()}
					in:motionScale={{
						start: 0.96,
						duration: DURATION.overlay,
						easing: EASE_SPRING,
						delay: staggerDelay(projectIndex, STAGGER_MS.group)
					}}
					out:motionScale|local={{ start: 0.98, duration: DURATION.fast }}
					use:droppable={{
						container: project.isPinned ? 'projects-pinned' : 'projects-regular',
						direction: 'horizontal',
						callbacks: {
							onDrop: (state: DragDropState<Project>) => onProjectDrop(state, project)
						}
					}}
				>
					<button
						type="button"
						class="project-select"
						aria-current={!workspace.showingFavorites && workspace.activeProjectId === project.id ? 'page' : undefined}
						use:draggable={{
							container: project.isPinned ? 'projects-pinned' : 'projects-regular',
							dragData: project,
							handle: '.project-select',
							attributes: { draggingClass: 'project-dragging' }
						}}
						onclick={() => workspace.selectProject(project.id)}
					>
						<span class="project-glyph">
							{#if Icon}<Icon size={16} strokeWidth={2.2} />{/if}
						</span>
						<span class="project-copy">
							<strong class:unnamed={!project.name}>{project.name ?? '未命名'}</strong>
						</span>
					</button>

					<Popover.Root
						open={projectMenuId === project.id}
						onOpenChange={(open) => (projectMenuId = open ? project.id : null)}
					>
						<Popover.Trigger>
							{#snippet child({ props })}
								<button
									{...props}
									type="button"
									class="project-menu-trigger"
									aria-label={`更多项目操作：${project.name ?? '未命名'}${project.isPinned ? '，已置顶' : ''}`}
									title={project.isPinned ? '更多操作，已置顶' : '更多操作'}
								>
									<EllipsisIcon size={12} strokeWidth={2} />
								</button>
							{/snippet}
						</Popover.Trigger>
						<Popover.Portal>
							<Popover.Content align="end" sideOffset={6} forceMount>
								{#snippet child({ wrapperProps, props, open })}
									{#if open}
										<div {...wrapperProps}>
											<div {...props} class="project-actions-menu" in:motionMenu out:motionMenu>
												<button
													type="button"
													class="project-menu-item"
													aria-label="编辑项目"
													onclick={() => {
														projectMenuId = null;
														workspace.openProjectDialog(project);
													}}
													title="编辑项目"
												>
													<span class="project-menu-icon"><PencilIcon size={15} strokeWidth={2} /></span>
												</button>
												<button
													type="button"
													class="project-menu-item pin-action"
													class:active={project.isPinned}
													data-project-pin-action
													aria-label={project.isPinned ? '取消置顶项目' : '置顶项目'}
													title={project.isPinned ? '取消置顶' : '置顶'}
													onclick={() => {
														projectMenuId = null;
														workspace.toggleProjectPinned(project.id);
													}}
												>
													<span class="project-menu-icon">
														{#if project.isPinned}
															<PinOffIcon size={15} strokeWidth={2} />
														{:else}
															<PinIcon size={15} strokeWidth={2} />
														{/if}
													</span>
												</button>
												<button
													type="button"
													class="project-menu-item danger"
													aria-label="移入回收站"
													title="移到回收站"
													onclick={() => {
														projectMenuId = null;
														void workspace.deleteProject(project.id);
													}}
												>
													<span class="project-menu-icon"><Trash2Icon size={15} strokeWidth={2} /></span>
												</button>
											</div>
										</div>
									{/if}
								{/snippet}
							</Popover.Content>
						</Popover.Portal>
					</Popover.Root>
				</div>
			{/each}

			<div class="new-project-dock">
				<button
					type="button"
					class="new-project"
					aria-label="新项目"
					title="新项目"
					onclick={() => workspace.openProjectDialog()}
				>
					<FolderPlusIcon size={14} strokeWidth={2} />
				</button>
			</div>
		</div>
	</nav>

	<section class="card-view" aria-label={viewTitle}>
		<header class="view-head"><h2>{viewTitle}</h2></header>

		<div class="card-stack">
			{#key cardViewKey}
			{#if workspace.showingFavorites && visibleCards.length === 0}
			<div class="empty-hint" in:popRise>
				<Mascot pose="welcome" size={132} />
				<p>还没有收藏</p>
			</div>
		{:else}
			<div class="grid">
				{#each visibleCards as card, cardIndex (card.id)}
					{@const cardProject = card.projectId === null ? null : projectsById[card.projectId]}
					{@const CardProjectIcon = projectIcon(cardProject?.icon ?? null)}
					<div
						class="cell"
						data-card-id={card.id}
						animate:flip={motionFlip()}
						in:motionFly={{
							y: 6,
							duration: DURATION.base,
							delay: staggerDelay(cardIndex, STAGGER_MS.card)
						}}
						out:motionFade|local={{ duration: DURATION.fast }}
					>
						<article
							class="card"
							data-card-actions
							class:favorite={card.isFavorite}
							use:draggable={{
								container: `cards-${workspace.activeProjectId ?? 'inbox'}-${card.isFavorite ? 'favorite' : 'regular'}`,
								dragData: card,
								disabled: workspace.showingFavorites,
								handle: '.card-hit',
								attributes: { draggingClass: 'card-dragging' }
							}}
							use:droppable={{
								container: `cards-${workspace.activeProjectId ?? 'inbox'}-${card.isFavorite ? 'favorite' : 'regular'}`,
								direction: 'grid',
								disabled: workspace.showingFavorites,
								callbacks: {
									onDrop: (state: DragDropState<Card>) => onCardDrop(state, card)
								}
							}}
						>
							<button type="button" class="card-hit" onclick={() => openCard(card)}>
								{#if card.title}<h3>{card.title}</h3>{/if}
								{#if preview(card)}
									<p>{preview(card)}</p>
								{:else if !card.title}
									<p class="blank">空白草稿</p>
								{/if}
								<div class="card-meta">
									{#if workspace.showingFavorites}
										<span class="card-project">
											<span
												class="card-project-glyph glyph-sheen"
												class:inbox={cardProject === null}
												style={cardProject
													? `--project-color: ${cardProject.color}; --project-foreground: ${paletteForeground(cardProject.color)}`
													: ''}
											>
												{#if cardProject && CardProjectIcon}
													<CardProjectIcon size={10} strokeWidth={2.4} />
												{:else}
													<InboxIcon size={10} strokeWidth={2} />
												{/if}
											</span>
											<span>{cardProject ? (cardProject.name ?? '未命名') : '未归档'}</span>
										</span>
									{/if}
									<time class="tabular-nums">{formatTime(card.updatedAt)}</time>
								</div>
							</button>

							<div class="card-actions">
								<button
									type="button"
									class="card-action trash-action"
									aria-label="移入回收站"
									title="移入回收站"
									onclick={() => workspace.deleteCard(card.id)}
								>
									<span class="card-action-icon"><Trash2Icon size={15} strokeWidth={2} /></span>
								</button>
								<button
									type="button"
									class="card-action star-action"
									class:active={card.isFavorite}
									data-icon-switch
									data-state={card.isFavorite ? 'active' : 'idle'}
									aria-label={card.isFavorite ? '取消收藏' : '收藏'}
									aria-pressed={card.isFavorite}
									title={card.isFavorite ? '取消收藏' : '收藏'}
									use:motionIconSwitch={card.isFavorite}
									onclick={() => workspace.toggleCardFavorite(card.id)}
								>
									<span class="card-action-icon">
										<span class="fx-icon-switch" aria-hidden="true">
											<StarIcon class="fx-icon-off" size={15} strokeWidth={2} />
											<StarIcon class="fx-icon-on" size={15} strokeWidth={2} fill="currentColor" />
										</span>
									</span>
								</button>
							</div>
						</article>
					</div>
				{/each}

				{#if !workspace.showingFavorites}
					<div class="cell ghost-cell" in:motionScale={{ start: 0.96, duration: DURATION.base }}>
						<button
							type="button"
							class="ghost-card"
							data-plus-trigger
							aria-label="新建卡片"
							onclick={() => editor.createAndOpen(workspace.activeProjectId)}
						>
							<PlusIcon size={17} strokeWidth={2} />
							<span>新建卡片</span>
						</button>
					</div>
				{/if}
			</div>
		{/if}
			{/key}
		</div>
		<span
			class="view-count-dock tabular-nums"
			aria-label={`${visibleCards.length} 张卡片`}
			title={`${visibleCards.length} 张卡片`}
		>{visibleCards.length}</span>
	</section>
</div>

<style>
	.board {
		display: grid;
		align-content: start;
		width: 100%;
		max-width: 92rem;
		margin: 0 auto;
		gap: 1.35rem;
		padding: 0.35rem 0 4rem;
	}

	.project-bar {
		min-width: 0;
		overflow-x: auto;
		overflow-y: hidden;
		overscroll-behavior-x: contain;
		scroll-padding-inline: 0.25rem 3.5rem;
		padding: 0.25rem 0 0.65rem;
	}

	.project-bar::-webkit-scrollbar {
		display: none;
	}

	.project-strip {
		display: flex;
		width: max-content;
		min-width: 100%;
		align-items: stretch;
		gap: 0.45rem;
	}

	.project-item {
		position: relative;
		display: block;
		flex: 0 0 auto;
		width: fit-content;
		min-width: 6.75rem;
		max-width: 9.25rem;
		border-radius: 999px;
		background: color-mix(in srgb, var(--color-surface-solid) 72%, transparent);
		box-shadow: 0 0 0 1px var(--color-border-subtle) inset;
		opacity: 1;
		transition-duration: var(--duration-base), var(--duration-fast), var(--duration-fast);
		transition-property: transform, background-color, box-shadow;
		transition-timing-function: var(--ease-standard);
	}

	.project-item.inbox {
		min-width: 6.25rem;
	}

	.project-item:not(.inbox) {
		background: color-mix(in srgb, var(--project-color) 6%, var(--color-surface-solid));
	}

	.project-item.inbox:not(.selected):hover {
		background: color-mix(in srgb, var(--color-surface-solid) 88%, transparent);
		box-shadow: 0 0 0 1px var(--color-border-strong) inset;
		transform: translateY(-1px);
	}

	.project-item:not(.inbox):not(.selected):not(.pinned):hover {
		background: color-mix(in srgb, var(--project-color) 12%, var(--color-surface-solid));
		box-shadow: 0 0 0 1px var(--color-border-strong) inset;
		transform: translateY(-1px);
	}

	.project-item.pinned {
		background: var(--color-surface-solid);
		box-shadow: 0 0 0 1px color-mix(in srgb, var(--project-color) 30%, var(--color-border-strong)) inset;
	}

	.project-item.pinned:not(.selected):hover {
		transform: translateY(-1px);
	}

	.project-item.selected {
		background: color-mix(in srgb, var(--project-color, var(--color-accent)) 16%, var(--color-surface-solid));
		box-shadow:
			0 0 0 1px var(--color-border-strong) inset,
			var(--shadow-control);
	}

	.project-item.inbox.selected,
	.project-item.pinned.selected {
		background: var(--color-surface-solid);
	}

	.project-item.pinned.selected {
		box-shadow:
			0 0 0 1px color-mix(in srgb, var(--project-color) 30%, var(--color-border-strong)) inset,
			var(--shadow-control);
	}

	.project-item:has(.project-select:global(.project-dragging)) {
		opacity: 0.55;
	}

	.project-select {
		display: flex;
		width: 100%;
		min-height: 2.5rem;
		align-items: center;
		gap: 0.45rem;
		padding: 0.3rem 0.5rem;
		border: 0;
		border-radius: inherit;
		background: transparent;
		color: var(--color-text);
		text-align: left;
	}

	.project-item:not(.inbox) .project-select {
		padding-right: 2.25rem;
	}

	.project-glyph {
		display: inline-grid;
		width: 1.5rem;
		height: 1.5rem;
		flex: 0 0 auto;
		place-items: center;
		background: transparent;
		color: color-mix(in srgb, var(--project-color) 82%, var(--color-text-strong));
	}

	.project-glyph.inbox {
		color: var(--color-text-muted);
	}

	.project-copy {
		display: flex;
		min-width: 0;
		align-items: center;
		gap: 0.32rem;
	}

	.project-copy strong {
		overflow: hidden;
		max-width: 4.25rem;
		font-size: 0.78rem;
		font-weight: 600;
		letter-spacing: -0.02em;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.project-copy strong.unnamed {
		color: var(--color-text-soft);
	}

	.project-menu-trigger {
		position: absolute;
		top: 50%;
		right: 0.5rem;
		display: grid;
		width: 1.5rem;
		height: 1.5rem;
		place-items: center;
		border: 0;
		border-radius: 999px;
		background: transparent;
		color: var(--color-text-soft);
		opacity: 0.38;
		transform: translateY(-50%);
		transition-duration: var(--duration-fast);
		transition-property: opacity, transform, background-color, color;
		transition-timing-function: var(--ease-enter);
	}

	.project-menu-trigger::before {
		position: absolute;
		inset: -0.5rem;
		content: '';
	}

	[data-project-actions]:hover .project-menu-trigger,
	[data-project-actions]:focus-within .project-menu-trigger,
	.project-menu-trigger[data-state='open'] {
		opacity: 1;
	}

	.project-menu-trigger:hover,
	.project-menu-trigger[data-state='open'] {
		background: var(--color-surface-muted);
		color: var(--color-text-strong);
	}

	.project-menu-trigger:active {
		transform: translateY(-50%) scale(var(--press-scale));
	}

	.project-actions-menu {
		z-index: 60;
		display: grid;
		grid-template-columns: repeat(3, 2.5rem);
		gap: 0.1rem;
		width: fit-content;
		padding: 0.25rem;
		border-radius: 999px;
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		backdrop-filter: blur(18px) saturate(1.05);
	}

	.project-actions-menu .project-menu-item {
		display: grid;
		width: 2.5rem;
		height: 2.5rem;
		place-items: center;
		padding: 0;
		border: 0;
		background: transparent;
		color: var(--color-text-muted);
	}

	.project-menu-icon {
		display: grid;
		width: 2rem;
		height: 2rem;
		place-items: center;
		border-radius: 999px;
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, transform;
		transition-timing-function: var(--ease-standard);
	}

	.project-actions-menu .project-menu-item:hover,
	.project-actions-menu .project-menu-item:focus-visible {
		outline: none;
		color: var(--color-accent-text);
	}

	.project-actions-menu .project-menu-item:hover .project-menu-icon,
	.project-actions-menu .project-menu-item:focus-visible .project-menu-icon {
		background: var(--color-accent-soft);
	}

	.project-actions-menu .project-menu-item:active .project-menu-icon {
		transform: scale(var(--press-scale));
	}

	.project-actions-menu .project-menu-item.danger:hover,
	.project-actions-menu .project-menu-item.danger:focus-visible {
		color: var(--color-danger);
	}

	.project-actions-menu .project-menu-item.danger:hover .project-menu-icon,
	.project-actions-menu .project-menu-item.danger:focus-visible .project-menu-icon {
		background: color-mix(in srgb, var(--color-danger) 14%, transparent);
	}

	.project-actions-menu .pin-action.active {
		color: var(--color-star);
	}

	.project-actions-menu .pin-action.active:hover .project-menu-icon,
	.project-actions-menu .pin-action.active:focus-visible .project-menu-icon {
		background: color-mix(in srgb, var(--color-star) 14%, transparent);
	}

	.card-action {
		display: grid;
		width: 2.5rem;
		height: 2.5rem;
		place-items: center;
		padding: 0;
		border: 0;
		background: transparent;
		color: var(--color-text-soft);
		opacity: 0;
		pointer-events: none;
		transition: opacity var(--duration-fast) var(--ease-enter);
	}

	.card-action-icon {
		display: grid;
		width: 1.75rem;
		height: 1.75rem;
		place-items: center;
		border-radius: 999px;
		transform: scale(0.86);
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, transform;
		transition-timing-function: var(--ease-enter);
	}

	[data-card-actions]:hover .card-action,
	[data-card-actions]:focus-within .card-action,
	.card-action.active {
		opacity: 1;
		pointer-events: auto;
	}

	[data-card-actions]:hover .card-action-icon,
	[data-card-actions]:focus-within .card-action-icon,
	.card-action.active .card-action-icon {
		transform: scale(1);
	}

	.card-action:hover {
		color: var(--color-accent-text);
	}

	.card-action:hover .card-action-icon {
		background: var(--color-accent-soft);
	}

	.trash-action:hover {
		color: var(--color-danger);
	}

	.trash-action:hover .card-action-icon {
		background: color-mix(in srgb, var(--color-danger) 13%, transparent);
	}

	.card-action:active .card-action-icon {
		transform: scale(var(--press-scale));
	}

	.star-action.active {
		color: var(--color-star);
	}

	.new-project-dock {
		position: sticky;
		right: 0;
		z-index: 2;
		display: grid;
		flex: 0 0 auto;
		place-items: center;
		padding-left: 1rem;
		background: linear-gradient(to right, transparent, var(--color-canvas) 1.25rem);
	}

	.new-project {
		display: grid;
		width: 2.5rem;
		height: 2.5rem;
		place-items: center;
		padding: 0;
		border: 0;
		border-radius: 999px;
		background: var(--color-surface-solid);
		box-shadow:
			0 0 0 1px var(--color-border-subtle) inset,
			var(--shadow-control);
		color: var(--color-text-muted);
		transition-duration: var(--duration-fast);
		transition-property: transform, background-color, color;
		transition-timing-function: var(--ease-standard);
	}

	.new-project:hover {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.new-project:hover :global(svg) {
		transform: rotate(90deg);
	}

	.new-project :global(svg),
	[data-plus-trigger] :global(svg) {
		transition: transform var(--duration-base) var(--ease-enter);
	}

	.card-view {
		display: grid;
		min-width: 0;
		gap: 1rem;
	}

	.view-head {
		display: flex;
		align-items: baseline;
		gap: 0.65rem;
		min-height: 2.7rem;
		padding: 0 0.2rem;
	}

	.view-head h2 {
		margin: 0;
		font-size: clamp(1.25rem, 2vw, 1.75rem);
		font-weight: 600;
		letter-spacing: -0.045em;
		line-height: 1;
		color: var(--color-text-strong);
	}

	.view-count-dock {
		position: fixed;
		right: clamp(1.1rem, 4vw, 3rem);
		bottom: 1.25rem;
		z-index: 6;
		color: var(--color-text-soft);
		font-size: 0.68rem;
		font-weight: 500;
		line-height: 1;
		pointer-events: none;
	}

	.card-stack {
		display: grid;
		min-width: 0;
	}

	.card-stack > .grid,
	.card-stack > .empty-hint {
		grid-area: 1 / 1;
	}

	.grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(min(100%, 13.5rem), 1fr));
		gap: 0.8rem;
	}

	.cell {
		display: grid;
		min-width: 0;
	}

	.card {
		position: relative;
		border-radius: var(--radius-card);
		background: var(--color-surface-solid);
		box-shadow:
			0 0 0 1px var(--color-border-subtle) inset,
			var(--shadow-card);
		opacity: 1;
		transition-duration: var(--duration-base), var(--duration-base), var(--duration-fast);
		transition-property: transform, box-shadow, opacity;
		transition-timing-function: var(--ease-standard);
		transition-delay: 0ms, 0ms, var(--drag-fade-delay);
	}

	.card:global(.card-dragging) {
		opacity: 0.55;
	}

	.card:hover {
		transform: translateY(-3px);
		box-shadow:
			0 0 0 1px var(--color-border-strong) inset,
			var(--shadow-card-hover);
	}

	.card:has(.card-hit:active) {
		transform: translateY(0);
		transition-duration: var(--duration-press);
	}

	.card-hit {
		display: flex;
		width: 100%;
		min-height: 9rem;
		flex-direction: column;
		padding: 1rem 1rem 0.8rem;
		border: 0;
		background: transparent;
		color: inherit;
		text-align: left;
	}

	.card-hit h3 {
		display: -webkit-box;
		overflow: hidden;
		margin: 0 0 0.35rem;
		-webkit-box-orient: vertical;
		-webkit-line-clamp: 2;
		line-clamp: 2;
		font-size: 0.92rem;
		font-weight: 600;
		letter-spacing: -0.025em;
		line-height: 1.4;
		color: var(--color-text-strong);
	}

	.card-hit > p {
		display: -webkit-box;
		overflow: hidden;
		margin: 0;
		-webkit-box-orient: vertical;
		-webkit-line-clamp: 3;
		line-clamp: 3;
		font-size: 0.8rem;
		line-height: 1.65;
		color: var(--color-text-muted);
	}

	.card-hit > p.blank {
		color: var(--color-text-soft);
	}

	.card-meta {
		display: flex;
		min-width: 0;
		align-items: center;
		gap: 0.55rem;
		margin-top: auto;
		padding-top: 0.75rem;
		padding-right: 5.35rem;
		font-size: 0.7rem;
		color: var(--color-text-soft);
	}

	.card-meta time {
		flex: 0 0 auto;
		margin-left: auto;
	}

	.card-project {
		display: inline-flex;
		min-width: 0;
		align-items: center;
		gap: 0.35rem;
	}

	.card-project > span:last-child {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.card-project-glyph {
		display: inline-grid;
		width: 1rem;
		height: 1rem;
		flex: 0 0 auto;
		place-items: center;
		border-radius: 0.35rem;
		background-color: var(--project-color);
		color: var(--project-foreground, var(--color-text-muted));
	}

	.card-project-glyph.inbox {
		background: var(--color-surface-muted);
	}

	.card-actions {
		position: absolute;
		right: 0.35rem;
		bottom: 0.35rem;
		display: grid;
		grid-template-columns: repeat(2, 2.5rem);
	}

	.ghost-card {
		display: grid;
		min-height: 9rem;
		height: 100%;
		place-items: center;
		align-content: center;
		gap: 0.5rem;
		border: 1.5px dashed var(--color-border-strong);
		border-radius: var(--radius-card);
		background: transparent;
		color: var(--color-text-soft);
		font-size: 0.76rem;
		font-weight: 500;
		transition-duration: var(--duration-fast);
		transition-property: border-color, background-color, color, transform;
		transition-timing-function: var(--ease-standard);
	}

	.ghost-card:hover {
		border-color: var(--color-accent);
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	[data-plus-trigger]:hover :global(svg) {
		transform: rotate(90deg) scale(var(--hover-pop));
	}

	.empty-hint {
		display: grid;
		min-height: 18rem;
		place-items: center;
		align-content: center;
		gap: 1rem;
		color: var(--color-text-soft);
		font-size: 0.84rem;
		text-align: center;
	}

	.empty-hint p {
		margin: 0;
	}

	@media (max-width: 720px) {
		.board {
			gap: 1.2rem;
		}

		.view-head h2 {
			font-size: 1.3rem;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.card:hover,
		.card:has(.card-hit:active) {
			transform: none;
		}

		.new-project:hover :global(svg),
		[data-plus-trigger]:hover :global(svg) {
			transform: none;
		}
	}
</style>
