<script lang="ts">
	import { Popover } from 'bits-ui';
	import { flip } from 'svelte/animate';
	import { onDestroy } from 'svelte';
	import {
		DURATION,
		motionFlip,
		motionFly,
		motionMenu,
		motionScale
	} from '$lib/motion';
	import CheckIcon from 'lucide-svelte/icons/check';
	import ChevronDownIcon from 'lucide-svelte/icons/chevron-down';
	import InboxIcon from 'lucide-svelte/icons/inbox';
	import ListTodoIcon from 'lucide-svelte/icons/list-todo';
	import PencilIcon from 'lucide-svelte/icons/pencil';
	import PlusIcon from 'lucide-svelte/icons/plus';
	import SquareIcon from 'lucide-svelte/icons/square';
	import Trash2Icon from 'lucide-svelte/icons/trash-2';
	import type { Project, Task } from '$lib/db';
	import { paletteForeground, projectIcon } from './palette';
	import { workspace } from './store.svelte';

	const ARM_RESET_MS = 2600;
	const DRAG_THRESHOLD_PX = 5;
	const NARROW_QUERY = '(max-width: 56rem)';

	type TaskPointer = {
		taskId: number;
		pointerId: number;
		startX: number;
		startY: number;
	};

	let adding = $state(false);
	let creating = $state(false);
	let newContent = $state('');
	let newError = $state('');
	let editingTaskId = $state<number | null>(null);
	let editContent = $state('');
	let editError = $state('');
	let completedOpen = $state(false);
	let stackExpanded = $state(true);
	let narrowOpen = $state(false);
	let isNarrow = $state(false);
	let armedTaskId = $state<number | null>(null);
	let projectMenuTaskId = $state<number | null>(null);
	let draggingTaskId = $state<number | null>(null);
	let taskDropLineY = $state<number | null>(null);
	let taskDropOrder: number[] | null = null;
	let taskPointer: TaskPointer | null = null;
	let suppressTaskClick = false;
	let clickResetFrame: number | undefined;
	let armTimer: ReturnType<typeof setTimeout> | undefined;
	let root: HTMLElement;
	let narrowTrigger: HTMLButtonElement;

	const activeTasks: Task[] = $derived.by(() =>
		workspace.tasks
			.filter((task) => task.completedAt === null)
			.sort((left, right) => left.sortOrder - right.sortOrder || left.id - right.id)
	);
	const completedTasks: Task[] = $derived.by(() =>
		workspace.tasks
			.filter((task) => task.completedAt !== null)
			.sort(
				(left, right) =>
					(right.completedAt ?? 0) - (left.completedAt ?? 0) || right.id - left.id
			)
	);
	const projectsById: Record<number, Project> = $derived.by(() =>
		Object.fromEntries(workspace.projects.map((project) => [project.id, project]))
	);
	const trashedProjectsById: Record<number, Project> = $derived.by(() =>
		Object.fromEntries(workspace.trash.projects.map((project) => [project.id, project]))
	);

	$effect(() => {
		const query = window.matchMedia(NARROW_QUERY);
		const update = () => {
			isNarrow = query.matches;
			if (!isNarrow) narrowOpen = false;
		};
		update();
		query.addEventListener('change', update);
		return () => query.removeEventListener('change', update);
	});

	onDestroy(() => {
		clearTimeout(armTimer);
		if (clickResetFrame !== undefined) cancelAnimationFrame(clickResetFrame);
	});

	function openCreator() {
		stackExpanded = true;
		narrowOpen = isNarrow || narrowOpen;
		adding = true;
		newError = '';
	}

	async function createTask() {
		if (creating) return;
		if (!newContent.trim()) {
			newError = '任务内容不能为空';
			return;
		}
		creating = true;
		const created = await workspace.createTask(newContent);
		creating = false;
		if (!created) return;
		newContent = '';
		newError = '';
		adding = false;
	}

	function beginEdit(task: Task) {
		editingTaskId = task.id;
		editContent = task.content;
		editError = '';
	}

	function cancelEdit() {
		editingTaskId = null;
		editContent = '';
		editError = '';
	}

	async function saveEdit(task: Task) {
		if (editingTaskId !== task.id) return;
		if (!editContent.trim()) {
			editError = '任务内容不能为空';
			return;
		}
		const saved = await workspace.updateTaskContent(task.id, editContent);
		if (saved && editingTaskId === task.id) cancelEdit();
	}

	function onEditKeydown(event: KeyboardEvent) {
		if (event.key !== 'Escape') return;
		event.preventDefault();
		cancelEdit();
	}

	function onCreateKeydown(event: KeyboardEvent) {
		if (event.key !== 'Escape') return;
		event.preventDefault();
		adding = false;
		newContent = '';
		newError = '';
	}

	function onTaskPointerDown(event: PointerEvent, taskId: number) {
		if (event.button !== 0 || !event.isPrimary) return;
		if (event.isTrusted && event.currentTarget instanceof Element) {
			event.currentTarget.setPointerCapture(event.pointerId);
		}
		if (clickResetFrame !== undefined) cancelAnimationFrame(clickResetFrame);
		clickResetFrame = undefined;
		suppressTaskClick = false;
		taskPointer = {
			taskId,
			pointerId: event.pointerId,
			startX: event.clientX,
			startY: event.clientY
		};
	}

	function onTaskPointerMove(event: PointerEvent) {
		if (!taskPointer || event.pointerId !== taskPointer.pointerId) return;
		if (draggingTaskId === null) {
			const distance = Math.hypot(
				event.clientX - taskPointer.startX,
				event.clientY - taskPointer.startY
			);
			if (distance < DRAG_THRESHOLD_PX) return;
			draggingTaskId = taskPointer.taskId;
			suppressTaskClick = true;
		}
		event.preventDefault();
		updateTaskDropSlot(event.clientX, event.clientY);
	}

	function updateTaskDropSlot(clientX: number, clientY: number) {
		const activeList = root.querySelector<HTMLElement>('.active-tasks');
		const draggedId = draggingTaskId;
		if (!activeList || draggedId === null) return;
		const listBounds = activeList.getBoundingClientRect();
		if (
			clientX < listBounds.left ||
			clientX > listBounds.right ||
			clientY < listBounds.top ||
			clientY > listBounds.bottom
		) {
			clearTaskDropSlot();
			return;
		}
		const rows = Array.from(
			activeList.querySelectorAll<HTMLElement>('[data-task-id][data-task-state="active"]')
		).filter((row) => Number(row.dataset.taskId) !== draggedId);
		const beforeRow = rows.find((row) => {
			const bounds = row.getBoundingClientRect();
			return clientY < bounds.top + bounds.height / 2;
		});
		if (rows.length === 0) {
			clearTaskDropSlot();
			return;
		}
		const orderedIds = rows.map((row) => Number(row.dataset.taskId));
		const insertionIndex = beforeRow
			? orderedIds.indexOf(Number(beforeRow.dataset.taskId))
			: orderedIds.length;
		orderedIds.splice(insertionIndex, 0, draggedId);
		const rowGap = Number.parseFloat(getComputedStyle(activeList).rowGap) || 0;
		const anchorBounds = (beforeRow ?? rows[rows.length - 1]).getBoundingClientRect();
		taskDropLineY = beforeRow
			? anchorBounds.top - listBounds.top - rowGap / 2
			: anchorBounds.bottom - listBounds.top + rowGap / 2;
		taskDropOrder = orderedIds;
	}

	function onTaskPointerUp(event: PointerEvent) {
		if (!taskPointer || event.pointerId !== taskPointer.pointerId) return;
		const orderedIds = taskDropOrder;
		const changed = orderedIds?.some((id, index) => activeTasks[index]?.id !== id) ?? false;
		const didDrag = draggingTaskId !== null;
		clearTaskPointer();
		if (!didDrag) return;
		event.preventDefault();
		if (changed && orderedIds) void workspace.reorderTasks(orderedIds);
		clickResetFrame = requestAnimationFrame(() => {
			suppressTaskClick = false;
			clickResetFrame = undefined;
		});
	}

	function onTaskPointerCancel(event: PointerEvent) {
		if (!taskPointer || event.pointerId !== taskPointer.pointerId) return;
		cancelTaskDrag();
	}

	function cancelTaskDrag() {
		clearTaskPointer();
		suppressTaskClick = false;
	}

	function clearTaskPointer() {
		taskPointer = null;
		draggingTaskId = null;
		clearTaskDropSlot();
	}

	function clearTaskDropSlot() {
		taskDropLineY = null;
		taskDropOrder = null;
	}

	function onTaskCopyClick(event: MouseEvent, task: Task) {
		if (suppressTaskClick) {
			event.preventDefault();
			suppressTaskClick = false;
			return;
		}
		beginEdit(task);
	}

	function confirmDelete(taskId: number) {
		clearTimeout(armTimer);
		if (armedTaskId === taskId) {
			armedTaskId = null;
			void workspace.deleteTaskPermanently(taskId);
			return;
		}
		armedTaskId = taskId;
		armTimer = setTimeout(() => (armedTaskId = null), ARM_RESET_MS);
	}

	function resetArmed(taskId: number) {
		if (armedTaskId === taskId) armedTaskId = null;
	}

	function closeNarrow(restoreFocus = false) {
		if (!narrowOpen) return;
		narrowOpen = false;
		if (restoreFocus) narrowTrigger?.focus();
	}

	function onWindowPointerdown(event: PointerEvent) {
		if (!narrowOpen || !(event.target instanceof Element)) return;
		if (root.contains(event.target) || event.target.closest('[data-task-project-menu]')) return;
		closeNarrow();
	}

	function onWindowKeydown(event: KeyboardEvent) {
		if (event.key !== 'Escape' || event.defaultPrevented) return;
		if (draggingTaskId !== null) {
			event.preventDefault();
			cancelTaskDrag();
			return;
		}
		if (narrowOpen) closeNarrow(true);
	}

	function assignedProject(task: Task): Project | null {
		return task.projectId === null
			? null
			: (projectsById[task.projectId] ?? trashedProjectsById[task.projectId] ?? null);
	}

	function projectLabel(task: Task): string {
		if (task.projectId === null) return '未分配项目';
		const active = projectsById[task.projectId];
		if (active) return `项目：${active.name ?? '未命名'}`;
		const trashed = trashedProjectsById[task.projectId];
		return trashed ? `项目已回收：${trashed.name ?? '未命名'}` : '未分配项目';
	}

	function assignProject(taskId: number, projectId: number | null) {
		projectMenuTaskId = null;
		void workspace.assignTaskProject(taskId, projectId);
	}
</script>

<svelte:window
	onpointerdown={onWindowPointerdown}
	onpointermove={onTaskPointerMove}
	onpointerup={onTaskPointerUp}
	onpointercancel={onTaskPointerCancel}
	onkeydown={onWindowKeydown}
	onblur={cancelTaskDrag}
/>

{#snippet projectGlyph(task: Task)}
	{@const assigned = assignedProject(task)}
	{@const AssignedIcon = projectIcon(assigned?.icon ?? null)}
	<span
		class="project-glyph glyph-sheen"
		class:unassigned={!assigned}
		style={assigned
			? `--task-project-color: ${assigned.color}; --task-project-foreground: ${paletteForeground(assigned.color)}`
			: ''}
	>
		{#if assigned && AssignedIcon}
			<AssignedIcon size={10} strokeWidth={2.5} />
		{:else}
			<InboxIcon size={10} strokeWidth={2.1} />
		{/if}
	</span>
{/snippet}

{#snippet projectPicker(task: Task)}
	<Popover.Root
		open={projectMenuTaskId === task.id}
		onOpenChange={(open) => (projectMenuTaskId = open ? task.id : null)}
	>
		<Popover.Trigger>
			{#snippet child({ props })}
				<button
					{...props}
					type="button"
					class="task-project"
					aria-label={projectLabel(task)}
					title={projectLabel(task)}
				>
					{@render projectGlyph(task)}
					{#if task.projectId !== null && trashedProjectsById[task.projectId]}
						<span class="recycled-label">已回收</span>
					{/if}
				</button>
			{/snippet}
		</Popover.Trigger>
		<Popover.Portal>
			<Popover.Content align="end" side="left" sideOffset={7} forceMount>
				{#snippet child({ wrapperProps, props, open })}
					{#if open}
						<div {...wrapperProps} data-task-project-menu>
							<div {...props} class="project-menu" in:motionMenu={{ x: 7 }} out:motionMenu={{ x: 4 }}>
								<p class="ui-label">分配项目</p>
								<button
									type="button"
									class="project-option"
									class:selected={task.projectId === null}
									aria-pressed={task.projectId === null}
									onclick={() => assignProject(task.id, null)}
								>
									<span class="option-glyph unassigned"><InboxIcon size={11} strokeWidth={2.1} /></span>
									<span>未分配</span>
								</button>
								{#each workspace.projects as project (project.id)}
									{@const OptionIcon = projectIcon(project.icon)}
									<button
										type="button"
										class="project-option"
										class:selected={task.projectId === project.id}
										aria-pressed={task.projectId === project.id}
										onclick={() => assignProject(task.id, project.id)}
									>
										<span
											class="option-glyph glyph-sheen"
											style={`--task-project-color: ${project.color}; --task-project-foreground: ${paletteForeground(project.color)}`}
										>
											{#if OptionIcon}<OptionIcon size={11} strokeWidth={2.5} />{/if}
										</span>
										<span>{project.name ?? '未命名'}</span>
									</button>
								{/each}
							</div>
						</div>
					{/if}
				{/snippet}
			</Popover.Content>
		</Popover.Portal>
	</Popover.Root>
{/snippet}

{#snippet taskRow(task: Task, completed: boolean)}
	<div class="task-row-wrap">
		<div class="task-capsule" class:completed data-task-actions>
			<button
				type="button"
				class="task-check"
				class:done={completed}
				aria-label={completed ? `恢复任务：${task.content}` : `完成任务：${task.content}`}
				aria-pressed={completed}
				title={completed ? '恢复任务' : '完成任务'}
				onclick={() => void workspace.toggleTaskCompleted(task.id)}
			>
				{#if completed}
					<CheckIcon size={17} strokeWidth={3.2} />
				{:else}
					<SquareIcon size={16} strokeWidth={2} />
				{/if}
			</button>

			{#if editingTaskId === task.id}
				<form
					class="task-edit"
					onsubmit={(event) => {
						event.preventDefault();
						void saveEdit(task);
					}}
				>
					<!-- svelte-ignore a11y_autofocus -->
					<input
						type="text"
						autofocus
						maxlength="240"
						aria-label="编辑任务"
						aria-invalid={editError ? 'true' : undefined}
						bind:value={editContent}
						onkeydown={onEditKeydown}
						onblur={() => void saveEdit(task)}
					/>
				</form>
			{:else}
				<button
					type="button"
					class="task-copy"
					aria-label={`编辑任务：${task.content}`}
					title={task.content}
					onpointerdown={(event) => {
						if (!completed) onTaskPointerDown(event, task.id);
					}}
					onclick={(event) => onTaskCopyClick(event, task)}
				>
					<span>{task.content}</span>
				</button>
			{/if}

			{@render projectPicker(task)}

			<div class="task-actions">
				<button
					type="button"
					class="task-action"
					aria-label={`编辑任务：${task.content}`}
					title="编辑"
					onclick={() => beginEdit(task)}
				>
					<PencilIcon size={13} strokeWidth={2} />
				</button>
				<button
					type="button"
					class="task-action danger"
					class:armed={armedTaskId === task.id}
					aria-label={armedTaskId === task.id
						? `再点一次永久删除任务：${task.content}`
						: `永久删除任务：${task.content}`}
					title={armedTaskId === task.id ? '再点一次确认' : '永久删除'}
					onclick={() => confirmDelete(task.id)}
					onblur={() => resetArmed(task.id)}
					onmouseleave={() => resetArmed(task.id)}
				>
					<Trash2Icon size={13} strokeWidth={2} />
				</button>
			</div>
		</div>
		{#if editingTaskId === task.id && editError}
			<span class="field-error" role="alert">{editError}</span>
		{/if}
	</div>
{/snippet}

<aside
	class="task-stack"
	class:narrow-open={narrowOpen}
	data-narrow-open={narrowOpen}
	aria-label="悬浮任务"
	bind:this={root}
>
	<button
		bind:this={narrowTrigger}
		type="button"
		class="task-narrow-trigger"
		data-task-narrow-trigger
		aria-label={`任务，${activeTasks.length} 项待完成`}
		aria-expanded={narrowOpen}
		aria-controls="task-panel"
		title="任务"
		onclick={() => {
			narrowOpen = !narrowOpen;
			stackExpanded = true;
		}}
	>
		<ListTodoIcon size={17} strokeWidth={2} />
		{#if activeTasks.length > 0}
			<span class="task-count tabular-nums" aria-hidden="true">{activeTasks.length}</span>
		{/if}
	</button>

	{#if !isNarrow || narrowOpen}
		<section
			id="task-panel"
			class="task-panel"
			in:motionMenu={{ x: 7, y: -4 }}
			out:motionMenu={{ x: 4, y: -2 }}
		>
			<header class="task-tools">
				<button
					type="button"
					class="task-tool task-toggle"
					data-task-toggle
					aria-label={stackExpanded ? '收起任务' : '展开任务'}
					aria-expanded={stackExpanded}
					title={stackExpanded ? '收起任务' : '展开任务'}
					onclick={() => (stackExpanded = !stackExpanded)}
				>
					<ListTodoIcon size={17} strokeWidth={2} />
					<span>任务</span>
					{#if activeTasks.length > 0}
						<small class="task-tool-count tabular-nums" aria-hidden="true">{activeTasks.length}</small>
					{/if}
				</button>
				<button
					type="button"
					class="task-tool add"
					data-task-add-trigger
					aria-label="新建任务"
					title="新建任务"
					onclick={openCreator}
				>
					<PlusIcon size={17} strokeWidth={2} />
				</button>
			</header>

			{#if stackExpanded}
				<div class="task-list-scroll">
					{#if adding}
						<div class="task-row-wrap" in:motionScale={{ start: 0.96, duration: DURATION.base }}>
							<form
								class="task-capsule task-create"
								onsubmit={(event) => {
									event.preventDefault();
									void createTask();
								}}
							>
								<!-- svelte-ignore a11y_autofocus -->
								<input
									type="text"
									autofocus
									maxlength="240"
									placeholder="记下一件事"
									aria-label="任务内容"
									aria-invalid={newError ? 'true' : undefined}
									bind:value={newContent}
									onkeydown={onCreateKeydown}
								/>
								<button type="submit" aria-label="添加任务" title="添加任务" disabled={creating}>
									<PlusIcon size={15} strokeWidth={2.2} />
								</button>
							</form>
							{#if newError}<span class="field-error" role="alert">{newError}</span>{/if}
						</div>
					{/if}

					<div class="active-tasks" aria-label="待完成任务">
						{#each activeTasks as task (task.id)}
							<div
								class="task-motion"
								class:task-dragging={draggingTaskId === task.id}
								data-task-id={task.id}
								data-task-state="active"
								data-task-motion="active"
								animate:flip={motionFlip()}
								in:motionFly|local={{ x: 12, duration: DURATION.overlay }}
								out:motionFly|local={{ x: 8, duration: DURATION.fast }}
							>
								{@render taskRow(task, false)}
							</div>
						{/each}
						{#if activeTasks.length > 1}
							<div
								class="task-drop-end"
								data-task-drop-end
								aria-hidden="true"
							></div>
						{/if}
						{#if draggingTaskId !== null && taskDropLineY !== null}
							<div
								class="task-drop-indicator"
								data-task-drop-indicator
								aria-hidden="true"
								style={`--task-drop-y: ${taskDropLineY}px`}
							></div>
						{/if}
					</div>

					{#if completedTasks.length > 0}
						<div class="completed-section" in:motionScale={{ start: 0.97, duration: DURATION.base }}> 
							<button
								type="button"
								class="completed-toggle"
								aria-expanded={completedOpen}
								title={completedOpen ? '收起已完成任务' : '展开已完成任务'}
								onclick={() => (completedOpen = !completedOpen)}
							>
								<CheckIcon size={14} strokeWidth={3} />
								<span>已完成</span>
								<small class="tabular-nums">{completedTasks.length}</small>
								<ChevronDownIcon class={completedOpen ? 'open' : undefined} size={14} strokeWidth={2} />
							</button>
							{#if completedOpen}
								<div class="completed-tasks" aria-label="已完成任务">
									{#each completedTasks as task (task.id)}
										<div
											class="task-motion"
											data-task-id={task.id}
											data-task-state="completed"
											data-task-motion="completed"
											animate:flip={motionFlip()}
											in:motionFly|local={{ x: 10, duration: DURATION.base }}
											out:motionFly|local={{ x: 7, duration: DURATION.fast }}
										>
											{@render taskRow(task, true)}
										</div>
									{/each}
								</div>
							{/if}
						</div>
					{/if}
				</div>
			{/if}
		</section>
	{/if}
</aside>

<style>
	.task-stack {
		position: fixed;
		top: 9.65rem;
		right: clamp(1.1rem, 2.5vw, 2rem);
		z-index: 14;
		width: min(18rem, calc(100vw - 2.2rem));
		pointer-events: none;
	}

	.task-panel {
		display: grid;
		justify-items: end;
		gap: 0.55rem;
		width: 100%;
		pointer-events: auto;
	}

	.task-tools {
		display: flex;
		justify-content: end;
		gap: 0.35rem;
	}

	.task-tool,
	.task-narrow-trigger {
		position: relative;
		display: grid;
		width: 2.5rem;
		height: 2.5rem;
		place-items: center;
		border: 0;
		border-radius: 999px;
		background: var(--color-surface-solid);
		box-shadow: var(--shadow-control);
		color: var(--color-text-muted);
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, transform;
		transition-timing-function: var(--ease-standard);
	}

	.task-tool.task-toggle {
		width: auto;
		grid-auto-flow: column;
		gap: 0.45rem;
		padding: 0 0.75rem;
		font-size: 0.78rem;
		font-weight: 600;
	}

	.task-tool-count {
		color: var(--color-text-soft);
		font-size: 0.68rem;
		font-weight: 500;
	}

	.task-tool:hover,
	.task-narrow-trigger:hover {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.task-tool:active,
	.task-narrow-trigger:active {
		transform: scale(var(--press-scale));
	}

	.task-tool.add:hover :global(svg) {
		transform: rotate(90deg) scale(var(--hover-pop));
	}

	.task-tool.add :global(svg) {
		transition: transform var(--duration-base) var(--ease-enter);
	}

	.task-count {
		position: absolute;
		right: -0.18rem;
		top: -0.18rem;
		display: grid;
		min-width: 1rem;
		height: 1rem;
		place-items: center;
		padding: 0 0.2rem;
		border-radius: 999px;
		background: var(--color-accent);
		box-shadow: 0 0 0 2px var(--color-canvas);
		color: var(--color-canvas-soft);
		font-size: 0.6rem;
		font-weight: 600;
		line-height: 1;
	}

	.task-list-scroll {
		display: grid;
		width: 100%;
		max-height: calc(100dvh - 13.35rem);
		gap: 0.55rem;
		overflow-y: auto;
		padding: 0.45rem 0.15rem 0.5rem;
	}

	.active-tasks,
	.completed-tasks {
		display: grid;
		justify-items: end;
		gap: 0.55rem;
	}

	.active-tasks {
		position: relative;
	}

	.task-motion,
	.task-row-wrap {
		display: grid;
		justify-items: end;
		width: 100%;
		gap: 0.3rem;
	}

	.task-motion.task-dragging {
		opacity: 0.55;
	}

	.task-drop-end {
		width: 100%;
		height: 1rem;
		margin-top: -0.55rem;
	}

	.task-drop-indicator {
		position: absolute;
		top: var(--task-drop-y);
		right: 0;
		z-index: 2;
		width: min(14rem, 100%);
		height: 2.5px;
		border-radius: 2px;
		background: var(--color-accent);
		transform: translateY(-50%);
		pointer-events: none;
	}

	.task-capsule {
		display: grid;
		grid-template-columns: 2.5rem minmax(4rem, 1fr) auto 5rem;
		align-items: center;
		width: fit-content;
		min-width: min(14rem, 100%);
		max-width: 100%;
		min-height: 2.75rem;
		padding: 0.12rem 0.22rem 0.12rem 0.1rem;
		border-radius: 999px;
		background: var(--color-surface-solid);
		box-shadow:
			0 0 0 1px var(--color-border-subtle) inset,
			var(--shadow-control);
		color: var(--color-text);
		transition-duration: var(--duration-fast);
		transition-property: box-shadow, transform, background-color;
		transition-timing-function: var(--ease-standard);
	}

	.task-capsule:hover,
	.task-capsule:focus-within {
		box-shadow:
			0 0 0 1px var(--color-border-strong) inset,
			var(--shadow-card-hover);
	}

	.task-capsule:has(button:active) {
		transform: scale(0.99);
	}

	.task-check,
	.task-project,
	.task-action,
	.task-create button {
		display: grid;
		width: 2.5rem;
		height: 2.5rem;
		place-items: center;
		border: 0;
		border-radius: 999px;
		background: transparent;
		color: var(--color-text-soft);
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, opacity, transform;
		transition-timing-function: var(--ease-enter);
	}

	.task-check:hover,
	.task-project:hover,
	.task-action:hover,
	.task-create button:hover {
		background: var(--color-surface-muted);
		color: var(--color-text-strong);
	}

	.task-check:active,
	.task-project:active,
	.task-action:active,
	.task-create button:active {
		transform: scale(var(--press-scale));
	}

	.task-check.done {
		color: var(--color-accent);
	}

	.task-copy {
		overflow: hidden;
		min-width: 0;
		min-height: 2.5rem;
		padding: 0 0.25rem;
		border: 0;
		background: transparent;
		color: var(--color-text-strong);
		font-size: 0.82rem;
		font-weight: 500;
		letter-spacing: -0.012em;
		text-align: left;
	}

	.active-tasks .task-copy {
		cursor: grab;
		touch-action: none;
		user-select: none;
	}

	.task-motion.task-dragging .task-copy {
		cursor: grabbing;
	}

	.task-copy span {
		display: block;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.task-capsule.completed .task-copy {
		color: var(--color-text-soft);
		text-decoration: line-through;
		text-decoration-thickness: 1px;
	}

	.task-edit {
		min-width: 0;
	}

	.task-edit input,
	.task-create input {
		width: 100%;
		min-width: 0;
		border: 0;
		background: transparent;
		color: var(--color-text-strong);
		font-size: 0.82rem;
		font-weight: 500;
		outline: none;
	}

	.task-edit input::placeholder,
	.task-create input::placeholder {
		color: var(--color-text-soft);
	}

	.task-project {
		position: relative;
		width: auto;
		min-width: 2.5rem;
		grid-auto-flow: column;
		gap: 0.25rem;
		padding: 0 0.55rem;
	}

	.project-glyph,
	.option-glyph {
		display: inline-grid;
		width: 1.35rem;
		height: 1.35rem;
		place-items: center;
		border-radius: 0.45rem;
		background-color: var(--task-project-color);
		color: var(--task-project-foreground, var(--color-text-muted));
	}

	.project-glyph.unassigned,
	.option-glyph.unassigned {
		background: var(--color-surface-muted);
		box-shadow: 0 0 0 1px var(--color-border-subtle) inset;
		color: var(--color-text-muted);
	}

	.recycled-label {
		font-size: 0.66rem;
		font-weight: 500;
		color: var(--color-danger);
		white-space: nowrap;
	}

	.task-actions {
		display: grid;
		grid-template-columns: repeat(2, 2.5rem);
	}

	.task-action {
		opacity: 0;
		pointer-events: none;
		transform: scale(0.82);
	}

	[data-task-actions]:hover .task-action,
	[data-task-actions]:focus-within .task-action,
	.task-action.armed {
		opacity: 1;
		pointer-events: auto;
		transform: scale(1);
	}

	.task-action.danger:hover {
		background: color-mix(in srgb, var(--color-danger) 14%, transparent);
		color: var(--color-danger);
	}

	.task-action.armed,
	.task-action.armed:hover {
		background: var(--color-danger);
		color: #fff8f6;
		animation: fx-arm-pulse 1s var(--ease-standard) infinite;
	}

	.field-error {
		max-width: calc(100% - 0.8rem);
		margin-right: 0.4rem;
		padding: 0.25rem 0.55rem;
		border-radius: 999px;
		background: color-mix(in srgb, var(--color-danger) 10%, var(--color-surface-solid));
		color: var(--color-danger);
		font-size: 0.68rem;
		font-weight: 500;
	}

	.task-create {
		grid-template-columns: minmax(0, 1fr) 2.5rem;
		width: 100%;
		padding-left: 0.85rem;
	}

	.completed-section {
		display: grid;
		justify-items: end;
		gap: 0.55rem;
	}

	.completed-toggle {
		display: inline-grid;
		grid-auto-flow: column;
		align-items: center;
		gap: 0.4rem;
		min-height: 2.5rem;
		padding: 0 0.65rem;
		border: 0;
		border-radius: 999px;
		background: color-mix(in srgb, var(--color-surface-solid) 82%, transparent);
		box-shadow: 0 0 0 1px var(--color-border-subtle) inset;
		color: var(--color-text-muted);
		font-size: 0.75rem;
		font-weight: 500;
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, transform;
		transition-timing-function: var(--ease-standard);
	}

	.completed-toggle:hover {
		background: var(--color-surface-solid);
		color: var(--color-text-strong);
	}

	.completed-toggle:active {
		transform: scale(var(--press-scale));
	}

	.completed-toggle small {
		color: var(--color-text-soft);
		font-size: 0.68rem;
	}

	.completed-toggle :global(svg:last-child) {
		transition: transform var(--duration-base) var(--ease-enter);
	}

	.completed-toggle :global(svg:last-child.open) {
		transform: rotate(180deg);
	}

	.task-narrow-trigger {
		display: none;
		pointer-events: auto;
	}

	:global(.project-menu) {
		z-index: 40;
		display: grid;
		min-width: 11rem;
		max-height: min(20rem, calc(100dvh - 2rem));
		gap: 0.25rem;
		overflow-y: auto;
		padding: 0.55rem;
		border-radius: var(--radius-control);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		color: var(--color-text);
	}

	:global(.project-menu .ui-label) {
		margin: 0.25rem 0.45rem 0.35rem;
	}

	:global(.project-option) {
		display: grid;
		grid-template-columns: auto minmax(0, 1fr);
		align-items: center;
		gap: 0.55rem;
		min-height: 2.5rem;
		padding: 0 0.55rem;
		border: 0;
		border-radius: 0.65rem;
		background: transparent;
		color: var(--color-text);
		font-size: 0.8rem;
		text-align: left;
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, transform;
		transition-timing-function: var(--ease-standard);
	}

	:global(.project-option:hover),
	:global(.project-option.selected) {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	:global(.project-option:active) {
		transform: scale(0.98);
	}

	:global(.project-option span:last-child) {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	@media (max-width: 56rem) {
		.task-stack {
			position: static;
			flex: 0 0 2.5rem;
			width: 2.5rem;
		}

		.task-narrow-trigger {
			display: grid;
		}

		.task-panel {
			position: fixed;
			top: 4.15rem;
			right: 1.1rem;
			width: min(18rem, calc(100vw - 2.2rem));
		}

		.task-list-scroll {
			max-height: calc(100dvh - 8rem);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.task-tool.add:hover :global(svg),
		.completed-toggle :global(svg:last-child.open),
		.task-capsule:has(button:active),
		.task-action,
		[data-task-actions]:hover .task-action,
		[data-task-actions]:focus-within .task-action {
			transform: none;
		}

		.task-action.armed {
			animation: none;
		}
	}
</style>
