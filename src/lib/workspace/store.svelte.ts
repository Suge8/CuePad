import {
	cuePadRepository as repo,
	type Card,
	type CreateProjectInput,
	type Project,
	type Tag,
	type Task,
	type ThemeSetting,
	type TrashSnapshot,
	type UpdateProjectInput,
	type UpdateTaskInput
} from '$lib/db';
import { createLatestWins } from '$lib/latest-wins';
import { DEFAULT_GLOBAL_SHORTCUT } from '$lib/shell/accelerator';
import { applyGlobalShortcut, updateGlobalShortcut } from '$lib/shell/shortcut';
import { LatestBooleanWriter } from './latest-boolean-writer';
import { mergePersistedPatch } from './merge-persisted';
import { mergePartitionOrder } from './reorder';
import {
	ACTIVE_PROJECT_KEY,
	INBOX_STORAGE_VALUE,
	adjacentProjectId,
	parseStoredProjectId,
	resolveActiveProjectId,
	type ProjectId
} from './view';

export type WorkspaceView = { mode: 'project' | 'favorites'; projectId: ProjectId };
export type ToastTone = 'success' | 'danger' | 'neutral';
export type ToastIcon = 'copy' | 'trash' | 'restore' | 'check' | 'error';
type ToastOptions = { detail?: string; tone?: ToastTone; icon?: ToastIcon };
type TaskWriteState = {
	desired: UpdateTaskInput;
	pending: UpdateTaskInput | null;
	failureMessage: string;
	done?: Promise<boolean>;
};

class WorkspaceStore {
	ready = $state(false);
	loadError = $state('');
	projects = $state<Project[]>([]);
	cards = $state<Card[]>([]);
	tags = $state<Tag[]>([]);
	tasks = $state<Task[]>([]);
	trash = $state<TrashSnapshot>({ projects: [], cards: [] });

	selectedCardId = $state<number | null>(null);
	selectedCardTags = $state<Tag[]>([]);
	view = $state<WorkspaceView>({ mode: 'project', projectId: null });
	activeProjectId: ProjectId = $derived(this.view.projectId);
	showingFavorites: boolean = $derived(this.view.mode === 'favorites');
	theme = $state<ThemeSetting>('system');
	globalShortcut = $state<string>(DEFAULT_GLOBAL_SHORTCUT);

	paletteOpen = $state(false);
	settingsOpen = $state(false);
	trashOpen = $state(false);
	projectDialog = $state<{ open: boolean; project: Project | null }>({ open: false, project: null });

	toast = $state({
		visible: false,
		message: '',
		detail: '',
		tone: 'neutral' as ToastTone,
		icon: 'check' as ToastIcon
	});
	#toastTimer: ReturnType<typeof setTimeout> | undefined;
	#activeProjectRestored = false;
	readonly #taskWrites = new Map<number, TaskWriteState>();
	readonly #deletingTaskIds = new Set<number>();
	static readonly #TOAST_VISIBLE_MS = 2200;

	readonly #projectPinWriter = new LatestBooleanWriter<Project>({
		write: async (id, isPinned) => {
			const project = await repo.setProjectPinned(id, isPinned);
			if (!project) throw new Error(`Project ${id} was not found.`);
			return project;
		},
		onSuccess: (id, project, desired) => {
			this.projects = this.projects.map((item) =>
				item.id === id ? mergePersistedPatch(item, project, { isPinned: desired }) : item
			);
		},
		onFailure: (id, persisted, error) => {
			this.projects = this.projects.map((item) =>
				item.id === id ? { ...item, isPinned: persisted } : item
			);
			this.showToast('置顶失败', { detail: messageOf(error), tone: 'danger' });
		}
	});

	readonly #cardFavoriteWriter = new LatestBooleanWriter<Card>({
		write: async (id, isFavorite) => {
			const card = await repo.updateCard(id, { isFavorite });
			if (!card) throw new Error(`Card ${id} was not found.`);
			return card;
		},
		onSuccess: (id, card, desired) => {
			this.cards = this.cards.map((item) =>
				item.id === id ? mergePersistedPatch(item, card, { isFavorite: desired }) : item
			);
		},
		onFailure: (id, persisted, error) => {
			this.cards = this.cards.map((item) =>
				item.id === id ? { ...item, isFavorite: persisted } : item
			);
			this.showToast('收藏失败', { detail: messageOf(error), tone: 'danger' });
		}
	});

	isEmptyWorkspace: boolean = $derived(this.projects.length === 0 && this.cards.length === 0);

	async init() {
		this.loadError = '';
		try {
			const settings = await repo.getSettings();
			if (settings.theme === 'light' || settings.theme === 'dark') this.theme = settings.theme;
			this.applyTheme();
			if (typeof settings.globalShortcut === 'string') this.globalShortcut = settings.globalShortcut;
			applyGlobalShortcut(this.globalShortcut).catch((error) => {
				this.showToast('全局快捷键未生效', { detail: messageOf(error), tone: 'danger' });
			});
			await Promise.all([this.#reloadWorkspace(), this.refreshTrash()]);
			this.ready = true;
		} catch (error) {
			// 主界面展示错误带重试，不用瞬时 toast
			this.loadError = messageOf(error);
		}
	}

	async #reloadWorkspace() {
		const [projects, cards, tags, tasks] = await Promise.all([
			repo.listProjects(),
			repo.listCards(),
			repo.listTags(),
			repo.listTasks()
		]);
		this.projects = projects;
		this.cards = cards;
		this.tags = tags;
		this.tasks = this.#mergeTaskIntents(tasks);
		const candidate = this.#activeProjectRestored
			? this.view.projectId
			: this.#readStoredProjectId();
		this.#activeProjectRestored = true;
		this.#setActiveProject(resolveActiveProjectId(projects, cards, candidate));
		if (this.selectedCardId !== null && !cards.some((card) => card.id === this.selectedCardId)) {
			await this.selectCard(null);
		}
	}

	#readStoredProjectId(): ProjectId | undefined {
		if (typeof localStorage === 'undefined') return undefined;
		try {
			return parseStoredProjectId(localStorage.getItem(ACTIVE_PROJECT_KEY));
		} catch (error) {
			this.showToast('项目选择未恢复', { detail: messageOf(error), tone: 'danger' });
			return undefined;
		}
	}

	#setActiveProject(projectId: ProjectId, mode = this.view.mode) {
		this.view = { mode, projectId };
		if (typeof localStorage === 'undefined') return;
		try {
			localStorage.setItem(
				ACTIVE_PROJECT_KEY,
				projectId === null ? INBOX_STORAGE_VALUE : String(projectId)
			);
		} catch (error) {
			this.showToast('项目选择未保存', { detail: messageOf(error), tone: 'danger' });
		}
	}

	selectProject(projectId: ProjectId) {
		if (
			typeof projectId === 'number' &&
			!this.projects.some((project) => project.id === projectId)
		) {
			return;
		}
		if (this.view.mode === 'project' && this.view.projectId === projectId) return;
		this.#setActiveProject(projectId, 'project');
	}

	toggleFavoritesView() {
		this.view = {
			...this.view,
			mode: this.showingFavorites ? 'project' : 'favorites'
		};
	}

	applyTheme() {
		if (typeof document === 'undefined') return;
		if (this.theme === 'system') delete document.documentElement.dataset.theme;
		else document.documentElement.dataset.theme = this.theme;
	}

	async setTheme(theme: ThemeSetting) {
		if (theme === this.theme) return;
		this.theme = theme;
		this.applyTheme();
		await repo.setSetting('theme', theme).catch((error) => {
			this.showToast('主题未保存', { detail: messageOf(error), tone: 'danger' });
		});
	}

	/** 注册/持久化/回滚全部在 updateGlobalShortcut 事务内串行；失败抛出由设置页展示，界面状态不变 */
	async setGlobalShortcut(accelerator: string): Promise<void> {
		await updateGlobalShortcut(accelerator, (value) => repo.setSetting('globalShortcut', value));
		this.globalShortcut = accelerator;
	}

	openProjectDialog(project: Project | null = null) {
		this.projectDialog = { open: true, project };
	}

	closeProjectDialog() {
		this.projectDialog = { open: false, project: this.projectDialog.project };
	}

	showToast(message: string, options: ToastOptions = {}) {
		if (this.#toastTimer) clearTimeout(this.#toastTimer);
		const tone = options.tone ?? 'neutral';
		this.toast = {
			visible: true,
			message,
			detail: options.detail ?? '',
			tone,
			icon: options.icon ?? (tone === 'danger' ? 'error' : 'check')
		};
		this.#toastTimer = setTimeout(
			() => (this.toast.visible = false),
			WorkspaceStore.#TOAST_VISIBLE_MS
		);
	}

	// ---- 项目 ----

	/** 成功返回项目，失败返回 null（调用方据此决定是否关闭弹窗、保留输入） */
	async createProject(input: Omit<CreateProjectInput, 'sortOrder'>): Promise<Project | null> {
		try {
			const sortOrder = this.projects.reduce((max, project) => Math.max(max, project.sortOrder + 1), 0);
			const project = await repo.createProject({ ...input, sortOrder });
			this.projects = [...this.projects, project];
			this.selectProject(project.id);
			return project;
		} catch (error) {
			this.showToast('创建项目失败', { detail: messageOf(error), tone: 'danger' });
			return null;
		}
	}

	/** 成功返回项目，失败返回 null */
	async updateProject(id: number, input: UpdateProjectInput): Promise<Project | null> {
		try {
			const project = await repo.updateProject(id, input);
			if (project) {
				this.projects = this.projects.map((item) =>
					item.id === id ? mergePersistedPatch(item, project, input) : item
				);
			}
			return project;
		} catch (error) {
			this.showToast('更新项目失败', { detail: messageOf(error), tone: 'danger' });
			return null;
		}
	}

	toggleProjectPinned(id: number) {
		const current = this.projects.find((project) => project.id === id);
		if (!current) return;
		const desired = !current.isPinned;
		this.projects = this.projects.map((project) =>
			project.id === id ? { ...project, isPinned: desired } : project
		);
		void this.#projectPinWriter.set(id, current.isPinned, desired);
	}

	async deleteProject(id: number) {
		const deletingActiveProject = this.activeProjectId === id;
		const adjacent = deletingActiveProject ? adjacentProjectId(this.projects, id) : null;
		try {
			await repo.softDeleteProject(id);
			if (deletingActiveProject) this.#setActiveProject(adjacent);
			await Promise.all([this.#reloadWorkspace(), this.refreshTrash()]);
			this.showToast('已回收', { icon: 'trash' });
		} catch (error) {
			this.showToast('删除项目失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async reorderProjects(orderedIds: number[]) {
		if (
			orderedIds.length !== this.projects.length ||
			new Set(orderedIds).size !== orderedIds.length ||
			orderedIds.some((id) => !this.projects.some((project) => project.id === id))
		) {
			return;
		}
		const order = new Map(orderedIds.map((id, index) => [id, index]));
		this.projects = this.projects.map((project) => ({
			...project,
			sortOrder: order.get(project.id)!
		}));
		try {
			await repo.reorderProjects(orderedIds);
		} catch (error) {
			this.showToast('排序未保存', { detail: messageOf(error), tone: 'danger' });
			await this.#reloadWorkspace();
		}
	}

	// ---- 卡片 ----

	/** 标签加载的「最新请求胜出」守卫：快速切卡时丢弃乱序返回的旧响应 */
	#tagLoad = createLatestWins();

	async selectCard(id: number | null) {
		this.selectedCardId = id;
		this.selectedCardTags = []; // 先清空，避免旧卡标签闪现
		if (id === null) return;
		const ticket = this.#tagLoad.next();
		const tags = await repo.listTagsForCard(id).catch(() => []);
		// 双重校验：票据防乱序，id 防目标漂移（含 selectCard(null) 后旧请求回写）
		if (this.#tagLoad.isCurrent(ticket) && this.selectedCardId === id) {
			this.selectedCardTags = tags;
		}
	}

	/** 只写库并返回新卡，不改列表状态；入列由 insertCard 在调用方的同步段完成，
	 * 保证「新卡入列」与「沉浸层挂载」落在同一次 flush，不存在可被绘制的中间态 */
	async createCard(projectId: number | null = null): Promise<Card | null> {
		try {
			const sortOrder = this.cards
				.filter((card) => card.projectId === projectId)
				.reduce((min, card) => Math.min(min, card.sortOrder - 1), 0);
			return await repo.createCard({ projectId, sortOrder });
		} catch (error) {
			this.showToast('创建卡片失败', { detail: messageOf(error), tone: 'danger' });
			return null;
		}
	}

	/** 同步入列（无 await） */
	insertCard(card: Card) {
		this.cards = [card, ...this.cards];
		this.selectProject(card.projectId);
	}

	toggleCardFavorite(id: number) {
		const current = this.cards.find((card) => card.id === id);
		if (!current) return;
		const desired = !current.isFavorite;
		this.cards = this.cards.map((card) =>
			card.id === id ? { ...card, isFavorite: desired } : card
		);
		void this.#cardFavoriteWriter.set(id, current.isFavorite, desired);
	}

	async deleteCard(id: number) {
		try {
			await repo.softDeleteCard(id);
			this.cards = this.cards.filter((card) => card.id !== id);
			if (this.selectedCardId === id) await this.selectCard(null);
			await this.refreshTrash();
			this.showToast('已回收', { icon: 'trash' });
		} catch (error) {
			this.showToast('删除卡片失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async reorderCards(orderedIds: number[]) {
		if (
			new Set(orderedIds).size !== orderedIds.length ||
			orderedIds.some((id) => !this.cards.some((card) => card.id === id))
		) {
			return;
		}
		const order = new Map(orderedIds.map((id, index) => [id, index]));
		this.cards = this.cards.map((card) => {
			const sortOrder = order.get(card.id);
			return sortOrder === undefined ? card : { ...card, sortOrder };
		});
		try {
			await repo.reorderCards(orderedIds);
		} catch (error) {
			this.showToast('排序未保存', { detail: messageOf(error), tone: 'danger' });
			await this.#reloadWorkspace();
		}
	}

	// ---- 任务 ----

	async createTask(content: string, projectId: number | null = null): Promise<Task | null> {
		const trimmed = content.trim();
		if (!trimmed) return null;
		if (projectId !== null && !this.projects.some((project) => project.id === projectId)) {
			return null;
		}
		try {
			const task = await repo.createTask({ content: trimmed, projectId });
			this.tasks = [task, ...this.tasks];
			return task;
		} catch (error) {
			this.showToast('创建任务失败', { detail: messageOf(error), tone: 'danger' });
			return null;
		}
	}

	updateTaskContent(id: number, content: string): Promise<boolean> {
		const task = this.tasks.find((item) => item.id === id);
		const trimmed = content.trim();
		if (!task || !trimmed) return Promise.resolve(false);
		if (task.content === trimmed) return Promise.resolve(true);
		return this.#queueTaskUpdate(id, { content: trimmed }, '任务内容未保存');
	}

	assignTaskProject(id: number, projectId: number | null): Promise<boolean> {
		const task = this.tasks.find((item) => item.id === id);
		if (!task) return Promise.resolve(false);
		if (projectId !== null && !this.projects.some((project) => project.id === projectId)) {
			return Promise.resolve(false);
		}
		if (task.projectId === projectId) return Promise.resolve(true);
		return this.#queueTaskUpdate(id, { projectId }, '任务项目未保存');
	}

	toggleTaskCompleted(id: number): Promise<boolean> {
		const task = this.tasks.find((item) => item.id === id);
		if (!task) return Promise.resolve(false);
		const completedAt = task.completedAt === null ? Date.now() : null;
		return this.#queueTaskUpdate(id, { completedAt }, '任务状态未保存');
	}

	async reorderTasks(orderedIds: number[]) {
		const baseTasks = [...this.tasks].sort(
			(left, right) => left.sortOrder - right.sortOrder || left.id - right.id
		);
		const mergedIds = mergePartitionOrder(
			baseTasks,
			orderedIds,
			(task) => task.completedAt === null
		);
		if (!mergedIds) return;
		const order = new Map(mergedIds.map((id, index) => [id, index]));
		this.tasks = this.tasks.map((task) => ({ ...task, sortOrder: order.get(task.id)! }));
		try {
			await repo.reorderTasks(orderedIds);
		} catch (error) {
			this.showToast('任务排序未保存', { detail: messageOf(error), tone: 'danger' });
			await this.#reloadTasks();
		}
	}

	async deleteTaskPermanently(id: number) {
		if (!this.tasks.some((task) => task.id === id)) return;
		const pendingWrite = this.#taskWrites.get(id)?.done;
		this.#deletingTaskIds.add(id);
		this.tasks = this.tasks.filter((task) => task.id !== id);
		try {
			await pendingWrite;
			await repo.deleteTaskPermanently(id);
		} catch (error) {
			this.#deletingTaskIds.delete(id);
			await this.#reloadTasks();
			this.showToast('任务删除失败', { detail: messageOf(error), tone: 'danger' });
			return;
		}
		this.#deletingTaskIds.delete(id);
	}

	#queueTaskUpdate(
		id: number,
		patch: UpdateTaskInput,
		failureMessage: string
	): Promise<boolean> {
		this.tasks = this.tasks.map((task) => (task.id === id ? applyTaskPatch(task, patch) : task));
		const active = this.#taskWrites.get(id);
		if (active) {
			active.desired = mergeTaskPatch(active.desired, patch);
			active.pending = mergeTaskPatch(active.pending, patch);
			active.failureMessage = failureMessage;
			return active.done!;
		}

		const state: TaskWriteState = { desired: patch, pending: patch, failureMessage };
		this.#taskWrites.set(id, state);
		state.done = this.#drainTaskWrites(id, state);
		return state.done;
	}

	async #drainTaskWrites(id: number, state: TaskWriteState): Promise<boolean> {
		try {
			while (state.pending) {
				const patch = state.pending;
				state.pending = null;
				const persisted = await repo.updateTask(id, patch);
				if (!persisted) throw new Error(`Task ${id} was not found.`);
				this.tasks = this.tasks.map((task) =>
					task.id === id
						? { ...task, updatedAt: Math.max(task.updatedAt, persisted.updatedAt) }
						: task
				);
			}
			return true;
		} catch (error) {
			state.pending = null;
			if (this.#taskWrites.get(id) === state) this.#taskWrites.delete(id);
			this.showToast(state.failureMessage, { detail: messageOf(error), tone: 'danger' });
			await this.#restoreTask(id, state);
			return false;
		} finally {
			if (this.#taskWrites.get(id) === state) this.#taskWrites.delete(id);
		}
	}

	async #restoreTask(id: number, failedState: TaskWriteState) {
		if (this.#deletingTaskIds.has(id)) return;
		try {
			const authoritative = (await repo.listTasks()).find((task) => task.id === id);
			if (!authoritative) {
				this.tasks = this.tasks.filter((task) => task.id !== id);
				return;
			}
			const active = this.#taskWrites.get(id);
			const restored =
				active && active !== failedState
					? applyTaskPatch(authoritative, active.desired)
					: authoritative;
			this.tasks = this.tasks.some((task) => task.id === id)
				? this.tasks.map((task) => (task.id === id ? restored : task))
				: [restored, ...this.tasks];
		} catch (error) {
			this.showToast('任务状态未恢复', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async #reloadTasks() {
		this.tasks = this.#mergeTaskIntents(await repo.listTasks());
	}

	#mergeTaskIntents(tasks: Task[]): Task[] {
		return tasks
			.filter((task) => !this.#deletingTaskIds.has(task.id))
			.map((task) => {
				const desired = this.#taskWrites.get(task.id)?.desired;
				return desired ? applyTaskPatch(task, desired) : task;
			});
	}

	// ---- 标签 ----

	async addTagToSelectedCard(name: string) {
		const trimmed = name.trim();
		// 快照提交时的卡：后续 await 期间切卡，标签仍落在原卡，UI 回填只在仍是同一张卡时生效
		const cardId = this.selectedCardId;
		if (!trimmed || cardId === null) return;
		try {
			const tag = await repo.createTag(trimmed);
			await repo.addTagToCard(cardId, tag.id);
			if (!this.tags.some((item) => item.id === tag.id)) {
				this.tags = [...this.tags, tag].sort((a, b) => a.name.localeCompare(b.name));
			}
			// 已切到别的卡：库已正确写入原卡，不领票不刷新，
			// 否则会作废新卡在途的 selectCard 请求，把新卡标签卡在空态
			if (this.selectedCardId !== cardId) return;
			const ticket = this.#tagLoad.next();
			const tags = await repo.listTagsForCard(cardId);
			if (this.selectedCardId === cardId && this.#tagLoad.isCurrent(ticket)) {
				this.selectedCardTags = tags;
			}
		} catch (error) {
			this.showToast('添加标签失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async setTagColor(tagId: number, color: string | null) {
		try {
			const tag = await repo.setTagColor(tagId, color);
			if (!tag) return;
			this.tags = this.tags.map((item) =>
				item.id === tagId ? mergePersistedPatch(item, tag, { color }) : item
			);
			this.selectedCardTags = this.selectedCardTags.map((item) =>
				item.id === tagId ? mergePersistedPatch(item, tag, { color }) : item
			);
		} catch (error) {
			this.showToast('标签颜色未保存', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async removeTagFromSelectedCard(tagId: number) {
		const cardId = this.selectedCardId;
		if (cardId === null) return;
		try {
			await repo.removeTagFromCard(cardId, tagId);
			// 切卡后不动新卡的 UI 状态（库已正确写入原卡）
			if (this.selectedCardId === cardId) {
				this.selectedCardTags = this.selectedCardTags.filter((tag) => tag.id !== tagId);
			}
		} catch (error) {
			this.showToast('移除标签失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	// ---- 回收站 ----

	async refreshTrash() {
		try {
			this.trash = await repo.listTrash();
		} catch (error) {
			this.showToast('读取回收站失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async restoreProject(id: number) {
		try {
			await repo.restoreProject(id);
			await Promise.all([this.#reloadWorkspace(), this.refreshTrash()]);
			this.showToast('已恢复', { icon: 'restore', tone: 'success' });
		} catch (error) {
			this.showToast('恢复失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async restoreCard(id: number) {
		try {
			await repo.restoreCard(id);
			await Promise.all([this.#reloadWorkspace(), this.refreshTrash()]);
			this.showToast('已恢复', { icon: 'restore', tone: 'success' });
		} catch (error) {
			this.showToast('恢复失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async destroyProject(id: number) {
		try {
			await repo.deleteProjectPermanently(id);
			await Promise.all([this.refreshTrash(), this.#reloadTasks()]);
			this.showToast('已永久删除', { icon: 'trash' });
		} catch (error) {
			this.showToast('永久删除失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async emptyTrash() {
		try {
			await repo.emptyTrash();
			await Promise.all([this.refreshTrash(), this.#reloadTasks()]);
			this.showToast('回收站已清空', { icon: 'trash' });
		} catch (error) {
			this.showToast('清空失败', { detail: messageOf(error), tone: 'danger' });
		}
	}

	async destroyCard(id: number) {
		try {
			await repo.deleteCardPermanently(id);
			await this.refreshTrash();
			this.showToast('已永久删除', { icon: 'trash' });
		} catch (error) {
			this.showToast('永久删除失败', { detail: messageOf(error), tone: 'danger' });
		}
	}
}

function mergeTaskPatch(
	base: UpdateTaskInput | null,
	override: UpdateTaskInput
): UpdateTaskInput {
	return base ? { ...base, ...override } : override;
}

function applyTaskPatch(task: Task, patch: UpdateTaskInput): Task {
	return {
		...task,
		...(patch.content === undefined ? {} : { content: patch.content }),
		...(patch.projectId === undefined ? {} : { projectId: patch.projectId }),
		...(patch.completedAt === undefined ? {} : { completedAt: patch.completedAt })
	};
}

function messageOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

export const workspace = new WorkspaceStore();
