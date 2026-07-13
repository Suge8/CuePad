<script lang="ts">
	import { DropdownMenu } from 'bits-ui';
	import {
		motionFade,
		motionFly,
		motionIconSwitch,
		motionMenu
	} from '$lib/motion';
	import ArrowLeftIcon from 'lucide-svelte/icons/arrow-left';
	import CheckIcon from 'lucide-svelte/icons/check';
	import ChevronDownIcon from 'lucide-svelte/icons/chevron-down';
	import CopyIcon from 'lucide-svelte/icons/copy';
	import InboxIcon from 'lucide-svelte/icons/inbox';
	import PencilLineIcon from 'lucide-svelte/icons/pencil-line';
	import SendIcon from 'lucide-svelte/icons/send';
	import StarIcon from 'lucide-svelte/icons/star';
	import CodeEditor from '$lib/editor/CodeEditor.svelte';
	import { formatSegments, parseSegments, trimSegment } from '$lib/editor/segments';
	import type { CardNumbering } from '$lib/db';
	import Button from '$lib/ui/Button.svelte';
	import {
		DISPATCH_TARGET_EVENT,
		copyPrompt,
		dispatchAvailable,
		dispatchPinnedTarget,
		dispatchPrompt,
		dispatchRecentTarget,
		dispatchTarget,
		dispatchTargets,
		setDispatchTarget,
		type DispatchApp
	} from './dispatch';
	import { editor } from './editor.svelte';
	import { formatTime } from './format';
	import { paletteForeground, projectIcon } from './palette';
	import { workspace } from './store.svelte';
	import TagRow from './TagRow.svelte';

	const card = $derived(editor.card);
	const project = $derived(
		workspace.projects.find((item) => item.id === card?.projectId) ?? null
	);
	const segments = $derived(parseSegments(editor.body));
	const numbering = $derived(editor.numbering);

	const NUMBERING_OPTIONS: { value: CardNumbering; label: string }[] = [
		{ value: 'none', label: '无' },
		{ value: 'decimal', label: '1.' },
		{ value: 'alpha', label: 'A.' },
		{ value: 'cjk', label: '一、' }
	];

	// 标题默认是按钮（边界清晰、不误触），点击才变输入框；按钮之外的顶栏空白全是拖拽区
	let editingTitle = $state(false);

	function focusAndSelect(node: HTMLInputElement) {
		node.focus();
		node.select();
	}

	function onTitleKeydown(event: KeyboardEvent) {
		if (event.key === 'Enter' || event.key === 'Escape') {
			// 阯断全局 Escape（否则会退出沉浸编辑）
			event.preventDefault();
			editingTitle = false;
		}
	}

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'Escape' && !event.defaultPrevented) {
			event.preventDefault();
			void editor.close();
		}
	}

	let dispatchTargetApp = $state<DispatchApp | null>(null);
	let recentDispatchApp = $state<DispatchApp | null>(null);
	let dispatchApps = $state<DispatchApp[]>([]);
	let pinnedDispatchApp = $state<DispatchApp | null>(null);
	let dispatchRefreshSequence = 0;
	const dispatchTargetName = $derived(dispatchTargetApp?.name ?? null);
	const pinnedBundleId = $derived(pinnedDispatchApp?.bundleId ?? null);
	const pinnedTargetUnavailable = $derived(
		Boolean(pinnedBundleId && !dispatchApps.some((app) => app.bundleId === pinnedBundleId))
	);

	function refreshDispatchTarget() {
		if (!dispatchAvailable) return;
		const sequence = ++dispatchRefreshSequence;
		void Promise.all([dispatchTarget(), dispatchRecentTarget(), dispatchTargets()]).then(
			([target, recent, apps]) => {
				if (sequence !== dispatchRefreshSequence) return;
				dispatchTargetApp = target;
				recentDispatchApp = recent;
				dispatchApps = apps;
				pinnedDispatchApp = dispatchPinnedTarget();
			}
		);
	}

	function chooseDispatchTarget(target: DispatchApp | null) {
		setDispatchTarget(target);
	}

	$effect(() => {
		if (!dispatchAvailable) return;
		refreshDispatchTarget();
		window.addEventListener('focus', refreshDispatchTarget);
		window.addEventListener(DISPATCH_TARGET_EVENT, refreshDispatchTarget);
		return () => {
			window.removeEventListener('focus', refreshDispatchTarget);
			window.removeEventListener(DISPATCH_TARGET_EVENT, refreshDispatchTarget);
		};
	});

	function copyText(text: string, label: string) {
		if (card) void copyPrompt({ text, cardId: card.id, label });
	}

	function sendText(text: string, label: string) {
		if (card) void dispatchPrompt({ text, cardId: card.id, label });
	}

	function segmentHint(segment: string): string {
		const firstLine = segment.split('\n').find((line) => line.trim());
		if (!firstLine) return '空白段';
		return firstLine.length > 18 ? `${firstLine.slice(0, 18)}…` : firstLine;
	}

	// 发给模型是主用途：默认复制排版后文本，原始全文在分段菜单里
	function copyFormatted() {
		copyText(formatSegments(editor.body, numbering), '全文');
	}

	function dispatchFormatted() {
		sendText(formatSegments(editor.body, numbering), '全文');
	}

	// 隐藏窗口（Cmd+H / 切后台）前强制保存
	$effect(() => {
		const flushOnHide = () => {
			if (document.visibilityState === 'hidden') editor.flushNow();
		};
		document.addEventListener('visibilitychange', flushOnHide);
		return () => document.removeEventListener('visibilitychange', flushOnHide);
	});
</script>

<svelte:window onkeydown={onKeydown} />

{#if card}
	{@const Icon = projectIcon(project?.icon ?? null)}
	<div class="focus" aria-label="沉浸编辑">
		<header class="focus-bar" data-tauri-drag-region>
			<Button
				variant="ghost"
				size="icon"
				aria-label="退出沉浸编辑（Esc）"
				title="退出沉浸编辑（Esc）"
				onclick={() => editor.close()}
			>
				<ArrowLeftIcon size={17} strokeWidth={2} />
			</Button>

			<DropdownMenu.Root>
				<DropdownMenu.Trigger>
					{#snippet child({ props })}
						<button {...props} class="project-chip" aria-label="移动到项目">
							<span class="chip-glyph glyph-sheen" style={project ? `--project-color: ${project.color}; --project-foreground: ${paletteForeground(project.color)}` : ''}>
								{#if project && Icon}
									<Icon size={12} strokeWidth={2.5} />
								{:else if !project}
									<InboxIcon size={12} strokeWidth={2} />
								{/if}
							</span>
							<span class="chip-name">{project ? (project.name ?? '未命名') : '未归档'}</span>
							<ChevronDownIcon size={13} strokeWidth={2} />
						</button>
					{/snippet}
				</DropdownMenu.Trigger>
				<DropdownMenu.Portal>
					<DropdownMenu.Content align="start" sideOffset={6} forceMount>
						{#snippet child({ wrapperProps, props, open })}
							{#if open}
								<div {...wrapperProps}>
									<div {...props} class="menu" in:motionMenu out:motionMenu>
										<DropdownMenu.Item
											class="menu-item"
											onSelect={() => editor.setProject(null)}
											textValue="未归档"
										>
											<span class="chip-glyph glyph-sheen"><InboxIcon size={12} strokeWidth={2.2} /></span>
											未归档
											{#if card.projectId === null}<CheckIcon size={14} strokeWidth={2.2} />{/if}
										</DropdownMenu.Item>
										{#each workspace.projects as item (item.id)}
											{@const ItemIcon = projectIcon(item.icon)}
											<DropdownMenu.Item
												class="menu-item"
												onSelect={() => editor.setProject(item.id)}
												textValue={item.name ?? '未命名'}
											>
												<span class="chip-glyph glyph-sheen" style={`--project-color: ${item.color}; --project-foreground: ${paletteForeground(item.color)}`}>
													{#if ItemIcon}<ItemIcon size={12} strokeWidth={2.5} />{/if}
												</span>
												{item.name ?? '未命名'}
												{#if card.projectId === item.id}<CheckIcon size={14} strokeWidth={2.2} />{/if}
											</DropdownMenu.Item>
										{/each}
									</div>
								</div>
							{/if}
						{/snippet}
					</DropdownMenu.Content>
				</DropdownMenu.Portal>
			</DropdownMenu.Root>

			{#if editingTitle}
				<input
					class="focus-title"
					type="text"
					placeholder="未命名"
					aria-label="标题"
					value={editor.title}
					oninput={(event) => editor.setTitle(event.currentTarget.value)}
					onblur={() => (editingTitle = false)}
					onkeydown={onTitleKeydown}
					maxlength="200"
					use:focusAndSelect
				/>
			{:else}
				<button
					type="button"
					class="title-button"
					class:unnamed={!editor.title}
					aria-label="编辑标题"
					onclick={() => (editingTitle = true)}
				>
					{#if !editor.title}
						<PencilLineIcon size={12} strokeWidth={2} />
						命名
					{:else}
						{editor.title}
					{/if}
				</button>
			{/if}

			<!-- 显式窗口拖拽区：占据顶栏中部弹性空白 -->
			<div class="bar-drag" data-tauri-drag-region></div>

			<div class="bar-tags"><TagRow /></div>

			<div class="bar-actions">
				<button
					type="button"
					class="bar-button"
					class:starred={card.isFavorite}
					aria-label={card.isFavorite ? '取消收藏' : '收藏'}
					aria-pressed={card.isFavorite}
					title={card.isFavorite ? '取消收藏' : '收藏'}
					data-icon-switch
					data-state={card.isFavorite ? 'active' : 'idle'}
					use:motionIconSwitch={card.isFavorite}
					onclick={() => editor.toggleFavorite()}
				>
					<span class="fx-icon-switch" aria-hidden="true">
						<StarIcon class="fx-icon-off" size={15} strokeWidth={2} />
						<StarIcon class="fx-icon-on" size={15} strokeWidth={2} fill="currentColor" />
					</span>
				</button>

				<button
					type="button"
					class="bar-button"
					aria-label="复制全文"
					title="复制全文"
					onclick={copyFormatted}
				>
					<CopyIcon size={15} strokeWidth={2} />
				</button>

				{#if dispatchAvailable}
					<div class="dispatch-control">
						<Button
							variant="secondary"
							size="sm"
							class="dispatch-button"
							disabled={!dispatchTargetApp}
							aria-label={dispatchTargetName ? `投送全文到 ${dispatchTargetName}` : '暂无投送目标'}
							title={dispatchTargetName ? `投送全文到 ${dispatchTargetName}` : '暂无投送目标'}
							onclick={dispatchFormatted}
						>
							<SendIcon size={14} strokeWidth={2} />
							<span class="dispatch-name">
								{dispatchTargetName ? `投送 → ${dispatchTargetName}` : '暂无目标'}
							</span>
						</Button>

						<DropdownMenu.Root onOpenChange={(open) => open && refreshDispatchTarget()}>
							<DropdownMenu.Trigger>
								{#snippet child({ props })}
									<Button
										{...props}
										variant="secondary"
										size="icon"
										class="dispatch-picker"
										aria-label="选择投送目标"
										title="选择投送目标"
									>
										<ChevronDownIcon size={13} strokeWidth={2} />
									</Button>
								{/snippet}
							</DropdownMenu.Trigger>
							<DropdownMenu.Portal>
								<DropdownMenu.Content align="end" sideOffset={6} forceMount>
									{#snippet child({ wrapperProps, props, open })}
										{#if open}
											<div {...wrapperProps}>
												<div {...props} class="menu target-menu" in:motionMenu out:motionMenu>
													<DropdownMenu.Item
														class="menu-item"
														onSelect={() => chooseDispatchTarget(null)}
														textValue="上一个应用"
													>
														<span class="target-copy">
															<strong>上一个应用</strong>
															<small>{recentDispatchApp?.name ?? '暂无'}</small>
														</span>
														{#if !pinnedBundleId}
															<CheckIcon class="target-check" size={14} strokeWidth={2.2} />
														{/if}
													</DropdownMenu.Item>
													<div class="menu-separator"></div>
													<p class="menu-label">固定到运行中的应用</p>
													{#each dispatchApps as app (app.bundleId)}
														<DropdownMenu.Item
															class="menu-item"
															onSelect={() => chooseDispatchTarget(app)}
															textValue={app.name}
														>
															<span class="target-name">{app.name}</span>
															{#if pinnedBundleId === app.bundleId}
																<CheckIcon class="target-check" size={14} strokeWidth={2.2} />
															{/if}
														</DropdownMenu.Item>
													{/each}
													{#if pinnedDispatchApp && pinnedTargetUnavailable}
														<DropdownMenu.Item class="menu-item" disabled textValue={pinnedDispatchApp.name}>
															<span class="target-copy">
																<strong>{pinnedDispatchApp.name}</strong>
																<small>未运行</small>
															</span>
															<CheckIcon class="target-check" size={14} strokeWidth={2.2} />
														</DropdownMenu.Item>
													{/if}
												</div>
											</div>
										{/if}
									{/snippet}
								</DropdownMenu.Content>
							</DropdownMenu.Portal>
						</DropdownMenu.Root>
					</div>
				{/if}

				{#if segments.length >= 2}
					<DropdownMenu.Root>
						<DropdownMenu.Trigger>
							{#snippet child({ props })}
								<Button {...props} variant="secondary" size="sm">
									分段
									<ChevronDownIcon size={13} strokeWidth={2} />
								</Button>
							{/snippet}
						</DropdownMenu.Trigger>
						<DropdownMenu.Portal>
							<DropdownMenu.Content align="end" sideOffset={6} forceMount>
								{#snippet child({ wrapperProps, props, open })}
									{#if open}
										<div {...wrapperProps}>
											<div {...props} class="menu" in:motionMenu out:motionMenu>
												<div class="numbering-row" role="group" aria-label="编号风格">
													<span class="numbering-label">编号</span>
													{#each NUMBERING_OPTIONS as option (option.value)}
														<button
															type="button"
															class="numbering-option"
															class:selected={numbering === option.value}
															aria-pressed={numbering === option.value}
															onclick={() => editor.setNumbering(option.value)}
														>{option.label}</button>
													{/each}
												</div>
												<div class="menu-separator"></div>
												{#each segments as segment, index (index)}
													<DropdownMenu.Item
														class="menu-item"
														onSelect={() => copyText(trimSegment(segment.text), `第 ${index + 1} 段`)}
														textValue={`第 ${index + 1} 段`}
													>
														<span class="segment-index tabular-nums">{index + 1}</span>
														<span class="segment-hint">{segmentHint(segment.text)}</span>
													</DropdownMenu.Item>
												{/each}
												{#if dispatchTargetName}
													<div class="menu-separator"></div>
													<p class="menu-label">投送 → {dispatchTargetName}</p>
													{#each segments as segment, index (index)}
														<DropdownMenu.Item
															class="menu-item"
															onSelect={() => sendText(trimSegment(segment.text), `第 ${index + 1} 段`)}
															textValue={`投送第 ${index + 1} 段`}
														>
															<SendIcon size={13} strokeWidth={2} />
															<span class="segment-index tabular-nums">{index + 1}</span>
															<span class="segment-hint">{segmentHint(segment.text)}</span>
														</DropdownMenu.Item>
													{/each}
												{/if}
												<div class="menu-separator"></div>
												<DropdownMenu.Item
													class="menu-item"
													onSelect={() => copyText(editor.body, '原始全文')}
													textValue="复制原始全文"
												>
													<CopyIcon size={13} strokeWidth={2} />
													复制原始全文
												</DropdownMenu.Item>
											</div>
										</div>
									{/if}
								{/snippet}
							</DropdownMenu.Content>
						</DropdownMenu.Portal>
					</DropdownMenu.Root>
				{/if}
			</div>
		</header>

		{#if editor.backupPrompt}
			<div
				class="backup-banner"
				role="alert"
				in:motionFly={{ y: -6 }}
				out:motionFly={{ y: -6 }}
			>
				<p>发现 {formatTime(editor.backupPrompt.savedAt)} 未保存的草稿备份，比当前内容更新</p>
				<div class="banner-actions">
					<Button variant="primary" size="sm" onclick={() => editor.restoreBackup()}>恢复</Button>
					<Button variant="ghost" size="sm" onclick={() => editor.discardBackup()}>丢弃</Button>
				</div>
			</div>
		{/if}

		<!-- 保存状态：常态（saved）零 UI，仅保存中/失败时浮现右下角 -->
		{#if editor.saveState !== 'saved'}
			<div
				class="save-state"
				data-state={editor.saveState}
				role="status"
				in:motionFly={{ y: 8 }}
				out:motionFly={{ y: 8 }}
			>
				{#if editor.saveState === 'saving'}
					正在保存…
				{:else}
					保存失败
					<button type="button" class="retry" onclick={() => editor.flushNow()}>重试</button>
				{/if}
			</div>
		{/if}

		<div class="focus-main">
			{#if editor.body === ''}
				<!-- 空正文线稿：打第一个字即消失 -->
				<div class="empty-canvas" aria-hidden="true" in:motionFade out:motionFade>
					<svg width="132" height="116" viewBox="0 0 132 116" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
						<path d="M32 14h48l20 20v56a9 9 0 0 1-9 9H32a9 9 0 0 1-9-9V23a9 9 0 0 1 9-9Z" />
						<path d="M80 14v20h20" />
						<path d="M38 48h40M38 62h40M38 76h24" />
						<path d="M92 104 118 78l7 7-26 26-10 3 3-10Z" />
						<path d="M112 26c.7 4.6 2.7 6.6 7.3 7.3-4.6.7-6.6 2.7-7.3 7.3-.7-4.6-2.7-6.6-7.3-7.3 4.6-.7 6.6-2.7 7.3-7.3Z" fill="currentColor" stroke="none" />
					</svg>
				</div>
			{/if}
			{#key editor.cardId}
				<CodeEditor
					value={editor.body}
					onChange={(value) => editor.setBody(value)}
					placeholder="开始写…"
					{numbering}
					onCopyBlock={(text) => copyText(trimSegment(text), '当前块')}
				/>
			{/key}
		</div>
	</div>
{/if}

<style>
	/* 高度链：overlay(flex) → .focus(flex列) → focus-main(flex:1) → editor-host(flex:1)，
	 * 每层 min-height:0，不用 height:100%（避免参照 grid auto 行的循环），
	 * 最终只有 CodeMirror 的 .cm-scroller 是滚动容器。
	 * 顶栏绝对定位悬浮：不占布局、无背景色条，内容从其下方滑过 */
	.focus {
		position: relative;
		display: flex;
		flex-direction: column;
		min-height: 0;
	}

	.focus-bar {
		position: absolute;
		inset: 0 0 auto 0;
		z-index: 10;
		display: flex;
		align-items: center;
		gap: 0.6rem;
		/* overlay 标题栏：左侧给 traffic lights 留位；底部 padding 是 scrim 渐隐缓冲区 */
		padding: 0.9rem 1.1rem 1rem 4.2rem;
		/* 渐隐 scrim：正文滑过顶栏时淡出，不穿模按钮 */
		background: linear-gradient(to bottom, var(--color-canvas-soft) 62%, transparent);
	}

	.bar-drag {
		flex: 1;
		min-width: 2rem;
		align-self: stretch;
	}

	/* 顶栏元素级联入场：随覆盖层挂载自左向右轻降，各播一次 */
	.focus-bar > :global(*) {
		animation: fx-bar-rise var(--duration-overlay) var(--ease-standard) backwards;
	}

	.focus-bar > :global(*:nth-child(2)) {
		animation-delay: var(--stagger-step);
	}

	.focus-bar > :global(*:nth-child(3)) {
		animation-delay: calc(var(--stagger-step) * 2);
	}

	.focus-bar > :global(*:nth-child(n + 4)) {
		animation-delay: calc(var(--stagger-step) * 3);
	}

	@media (prefers-reduced-motion: reduce) {
		.focus-bar > :global(*) {
			animation: none;
		}
	}

	.project-chip {
		display: inline-flex;
		align-items: center;
		gap: 0.45rem;
		min-height: 2.5rem;
		padding: 0 0.7rem;
		border: 0;
		border-radius: var(--radius-control);
		background: var(--color-surface-muted);
		color: var(--color-text);
		font-size: 0.8rem;
		font-weight: 600;
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard);
	}

	.project-chip:hover {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.chip-glyph {
		display: inline-grid;
		width: 1.15rem;
		height: 1.15rem;
		place-items: center;
		border-radius: 0.4rem;
		background: var(--project-color, var(--color-surface-solid));
		color: var(--project-foreground, var(--color-text-muted));
	}

	.chip-name {
		max-width: 10rem;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.save-state {
		position: absolute;
		right: 1rem;
		bottom: 1rem;
		z-index: 10;
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		min-height: 1.7rem;
		padding: 0 0.65rem;
		border-radius: 999px;
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-control);
		color: var(--color-text-muted);
		font-size: 0.72rem;
		font-weight: 600;
		letter-spacing: 0.02em;
		white-space: nowrap;
	}

	.save-state[data-state='error'] {
		background: color-mix(in srgb, var(--color-danger) 12%, var(--color-surface-solid));
		color: var(--color-danger);
	}

	.retry {
		border: 0;
		padding: 0.1rem 0.45rem;
		border-radius: 999px;
		background: var(--color-danger);
		color: var(--color-canvas-soft);
		font-size: 0.7rem;
		font-weight: 600;
	}

	.bar-actions {
		display: flex;
		align-items: center;
		gap: 0.4rem;
		margin-left: auto;
	}

	.dispatch-control {
		display: flex;
		align-items: center;
		gap: 1px;
	}

	.bar-actions :global(.dispatch-button) {
		max-width: 13rem;
		border-radius: 0.75rem 0.35rem 0.35rem 0.75rem;
	}

	.dispatch-control :global(.dispatch-picker) {
		width: 2.5rem;
		height: 2.5rem;
		padding: 0;
		border-radius: 0.35rem 0.75rem 0.75rem 0.35rem;
	}

	.dispatch-name {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.bar-button {
		display: grid;
		width: 2.5rem;
		height: 2.5rem;
		place-items: center;
		border: 0;
		border-radius: var(--radius-control);
		background: var(--color-surface-solid);
		color: var(--color-text-soft);
		box-shadow: var(--shadow-control);
		transition-duration: var(--duration-fast);
		transition-property: background-color, color, transform;
		transition-timing-function: var(--ease-standard);
	}

	.bar-button:hover {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.bar-button:active {
		transform: scale(var(--press-scale));
	}

	.bar-button.starred {
		color: var(--color-star);
	}

	.menu {
		z-index: 60;
		display: grid;
		min-width: 12rem;
		max-height: 20rem;
		overflow-y: auto;
		gap: 0.15rem;
		padding: 0.35rem;
		border: 1px solid var(--color-border-subtle);
		border-radius: var(--radius-card);
		background: var(--color-surface-raised);
		box-shadow: var(--shadow-float);
		backdrop-filter: blur(18px) saturate(1.05);
	}

	.menu :global(.menu-item) {
		display: flex;
		align-items: center;
		gap: 0.55rem;
		min-height: 2.35rem;
		padding: 0 0.65rem;
		border-radius: 0.75rem;
		color: var(--color-text);
		font-size: 0.82rem;
		font-weight: 500;
		outline: none;
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard);
	}

	.menu :global(.menu-item[data-highlighted]) {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.numbering-row {
		display: flex;
		align-items: center;
		gap: 0.3rem;
		padding: 0.25rem 0.4rem;
	}

	.numbering-label {
		margin-right: 0.25rem;
		color: var(--color-text-soft);
		font-size: 0.72rem;
		font-weight: 600;
	}

	.numbering-option {
		min-width: 2rem;
		padding: 0.25rem 0.45rem;
		border: 0;
		border-radius: 0.55rem;
		background: transparent;
		color: var(--color-text-muted);
		font-size: 0.76rem;
		font-weight: 600;
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard);
	}

	.numbering-option:hover {
		background: var(--color-surface-muted);
		color: var(--color-text);
	}

	.numbering-option.selected {
		background: var(--color-accent-soft);
		color: var(--color-accent-text);
	}

	.menu-separator {
		height: 1px;
		margin: 0.2rem 0.4rem;
		background: var(--color-border-subtle);
	}

	.menu-label {
		margin: 0.25rem 0.65rem 0.15rem;
		color: var(--color-text-soft);
		font-size: 0.68rem;
		font-weight: 600;
		letter-spacing: 0.04em;
	}

	.target-menu {
		min-width: 16rem;
	}

	.target-copy {
		display: grid;
		gap: 0.1rem;
		min-width: 0;
	}

	.target-copy strong,
	.target-name {
		overflow: hidden;
		font-size: 0.82rem;
		font-weight: 500;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.target-copy small {
		color: var(--color-text-soft);
		font-size: 0.68rem;
	}

	.target-check {
		flex-shrink: 0;
		margin-left: auto;
	}

	.target-menu :global(.menu-item[data-disabled]) {
		opacity: 0.48;
	}

	.segment-index {
		display: inline-grid;
		width: 1.4rem;
		height: 1.4rem;
		place-items: center;
		border-radius: 0.5rem;
		background: var(--color-surface-muted);
		color: var(--color-text-muted);
		font-size: 0.72rem;
		font-weight: 600;
	}

	.segment-hint {
		overflow: hidden;
		max-width: 14rem;
		color: var(--color-text-muted);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	/* 悬浮在顶栏下方，不占布局 */
	.backup-banner {
		position: absolute;
		top: 4rem;
		left: 50%;
		z-index: 10;
		translate: -50% 0;
		display: flex;
		align-items: center;
		gap: 1rem;
		max-width: min(36rem, calc(100vw - 2rem));
		padding: 0.55rem 0.6rem 0.55rem 1rem;
		border: 1px solid color-mix(in srgb, var(--color-star) 35%, transparent);
		border-radius: var(--radius-card);
		background: color-mix(in srgb, var(--color-star) 10%, var(--color-surface-solid));
		box-shadow: var(--shadow-float);
	}

	.backup-banner p {
		margin: 0;
		font-size: 0.82rem;
		color: var(--color-text);
	}

	.banner-actions {
		display: flex;
		gap: 0.35rem;
	}

	.focus-main {
		position: relative;
		display: flex;
		flex: 1;
		min-height: 0;
	}

	.empty-canvas {
		position: absolute;
		inset: 0;
		display: grid;
		place-items: center;
		pointer-events: none;
		color: var(--color-border-strong);
	}

	.focus-main > :global(.editor-host) {
		flex: 1;
		min-width: 0;
		min-height: 0;
	}

	/* 标题编辑态：定宽不吃满中部，拖窗口不会误点 */
	.focus-title {
		flex: 0 1 auto;
		width: 14rem;
		min-width: 4rem;
		padding: 0.3rem 0.45rem;
		border: 0;
		border-radius: 0.6rem;
		background: var(--color-surface-muted);
		color: var(--color-text-strong);
		font-size: 0.95rem;
		font-weight: 600;
		letter-spacing: -0.02em;
		text-overflow: ellipsis;
	}

	/* 标题显示态：明确的按钮边界，hover 才提示可点，其余空白都能拖窗口 */
	.title-button {
		display: inline-flex;
		align-items: center;
		gap: 0.3rem;
		flex: 0 1 auto;
		max-width: 14rem;
		min-height: 1.9rem;
		padding: 0 0.45rem;
		border: 0;
		border-radius: 0.6rem;
		background: transparent;
		color: var(--color-text-strong);
		font-size: 0.95rem;
		font-weight: 600;
		letter-spacing: -0.02em;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		transition:
			background-color var(--duration-fast) var(--ease-standard),
			color var(--duration-fast) var(--ease-standard);
	}

	.title-button:hover {
		background: var(--color-surface-muted);
	}

	.title-button.unnamed {
		padding: 0 0.6rem;
		border: 1px dashed var(--color-border-strong);
		color: var(--color-text-soft);
		font-size: 0.78rem;
	}

	.title-button.unnamed:hover {
		background: var(--color-surface-muted);
		color: var(--color-text);
	}

	/* 标签在顶栏不换行，多标签时横向滚 */
	.bar-tags {
		max-width: 22rem;
		overflow-x: auto;
		scrollbar-width: none;
	}

	/* 顶栏标签横滚不显滚动条（scrollbar-width 仅 Firefox，WebKit 要伪元素） */
	.bar-tags::-webkit-scrollbar {
		display: none;
	}

	.bar-tags :global(.tag-row) {
		flex-wrap: nowrap;
	}

	.focus-title:focus {
		outline: none;
	}

	.focus-title::placeholder {
		color: var(--color-text-soft);
	}

	/* 小窗响应：不缩放，按优先级收缩/隐藏低频元素 */
	@media (max-width: 900px) {
		.focus-title {
			width: 9rem;
		}

		.title-button {
			max-width: 9rem;
		}

		.bar-tags {
			max-width: 11rem;
		}

		.chip-name {
			max-width: 6rem;
		}
	}

	@media (max-width: 680px) {
		.focus-bar {
			gap: 0.4rem;
			padding: 0.7rem 0.75rem 0.9rem 4rem;
		}

		.focus-title {
			width: auto;
			flex: 1 1 4rem;
		}

		.title-button {
			max-width: 7rem;
		}

		.bar-drag {
			min-width: 0.5rem;
		}

		.bar-tags {
			display: none;
		}

		.dispatch-name {
			display: none;
		}
	}
</style>
