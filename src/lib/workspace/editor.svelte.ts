import { cuePadRepository as repo, type Card, type CardNumbering, type UpdateCardInput } from '$lib/db';
import { Autosave, type SaveState } from '$lib/editor/autosave';
import {
	clearBackup,
	readBackup,
	shouldOfferRestore,
	writeBackup,
	type DraftBackup
} from '$lib/editor/backup';
import { mergePersistedPatch } from './merge-persisted';
import { workspace } from './store.svelte';

/**
 * 沉浸编辑状态：当前卡片草稿（title/body）+ 自动保存 + 失败备份。
 * Autosave 实例按卡片创建（save 回调闭包绑定 cardId），切卡先 flush 旧实例，
 * 从根上杜绝「保存在途时切卡写错卡」的竞态。
 */
class EditorStore {
	cardId = $state<number | null>(null);
	title = $state('');
	body = $state('');
	// 编号与 title/body 同为草稿：异步 commit 在途时复制/投送读这里，不读库快照
	numbering = $state<CardNumbering>('none');
	saveState = $state<SaveState>('saved');
	backupPrompt = $state<DraftBackup | null>(null);
	#autosave: Autosave<UpdateCardInput> | null = null;

	card: Card | null = $derived(workspace.cards.find((card) => card.id === this.cardId) ?? null);
	isOpen: boolean = $derived(this.cardId !== null);

	async open(id: number) {
		const card = workspace.cards.find((item) => item.id === id);
		if (!card) return;
		// 旧卡 Autosave 的 save 回调闭包绑定旧 cardId，后台 flush 不会写错卡；
		// 沉浸态在任何 await 前同步建立，overlay 与列表更新同帧渲染，无中间闪烁。
		const previous = this.#autosave;
		this.cardId = id;
		this.title = card.title ?? '';
		this.body = card.body ?? '';
		this.numbering = card.numbering;
		this.saveState = 'saved';
		// selectCard 的同步段会立即清空旧卡标签并发起加载（乱序由 latest-wins 守卫），
		// 必须在任何 await 之前调用，否则旧卡 flush 期间新卡会渲染出旧标签
		if (workspace.selectedCardId !== id) void workspace.selectCard(id);
		this.#autosave = new Autosave({
			save: (patch) => this.#persist(id, patch),
			onState: (state) => (this.saveState = state)
		});
		const backup = readBackup(id);
		this.backupPrompt = shouldOfferRestore(backup, card) ? backup : null;
		if (backup && !this.backupPrompt) clearBackup(id);
		await previous?.flush();
	}

	async createAndOpen(projectId: number | null = null) {
		const card = await workspace.createCard(projectId);
		if (!card) return;
		// 入列与 open 的同步段在同一个同步块内（无 await 间隔）：
		// 列表更新与沉浸层挂载同一次 flush，消灭「卡已入列但 overlay 未盖」的中间 DOM 态
		workspace.insertCard(card);
		await this.open(card.id);
	}

	async close() {
		await this.#autosave?.flush();
		this.cardId = null;
		this.backupPrompt = null;
	}

	/** 隐藏窗口/退出等场景下的强制保存；失败不抛出，备份已落 localStorage。 */
	flushNow(): Promise<void> {
		return this.#autosave?.flush() ?? Promise.resolve();
	}

	setTitle(value: string) {
		this.title = value;
		this.#autosave?.schedule({ title: value === '' ? null : value });
	}

	setBody(value: string) {
		this.body = value;
		this.#autosave?.schedule({ body: value === '' ? null : value });
	}

	setProject(projectId: number | null) {
		if (projectId === this.card?.projectId) return;
		void this.#autosave?.commit({ projectId });
	}

	setNumbering(numbering: CardNumbering) {
		if (numbering === this.numbering) return;
		this.numbering = numbering;
		void this.#autosave?.commit({ numbering });
	}

	toggleFavorite() {
		if (this.cardId !== null) workspace.toggleCardFavorite(this.cardId);
	}

	restoreBackup() {
		const backup = this.backupPrompt;
		if (!backup) return;
		this.title = backup.title ?? '';
		this.body = backup.body ?? '';
		this.backupPrompt = null;
		void this.#autosave?.commit({ title: backup.title, body: backup.body });
	}

	discardBackup() {
		if (this.cardId !== null) clearBackup(this.cardId);
		this.backupPrompt = null;
	}

	async #persist(id: number, patch: UpdateCardInput) {
		// 备份快照取自当前草稿，只对仍在编辑的卡成立；
		// 切卡后的后台 flush 若仍写备份，会把新卡草稿当成旧卡内容，
		// 保存失败时“恢复”会用错误内容覆盖旧卡
		if (this.cardId === id) {
			writeBackup(id, {
				title: this.title === '' ? null : this.title,
				body: this.body === '' ? null : this.body,
				savedAt: Date.now()
			});
		}
		const card = await repo.updateCard(id, patch);
		clearBackup(id);
		if (!card) return;
		workspace.cards = workspace.cards.map((item) =>
			item.id === id ? mergePersistedPatch(item, card, patch) : item
		);
	}
}

export const editor = new EditorStore();
