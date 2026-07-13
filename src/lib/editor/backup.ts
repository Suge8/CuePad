const KEY_PREFIX = 'cuepad:draft-backup:';

export interface DraftBackup {
	title: string | null;
	body: string | null;
	savedAt: number;
}

function keyOf(cardId: number): string {
	return KEY_PREFIX + cardId;
}

/** 保存前写入草稿备份；备份是保险机制，写入失败只记录、不阻塞真正的保存。 */
export function writeBackup(cardId: number, backup: DraftBackup) {
	try {
		localStorage.setItem(keyOf(cardId), JSON.stringify(backup));
	} catch (error) {
		console.warn('draft backup write failed', error);
	}
}

export function readBackup(cardId: number): DraftBackup | null {
	try {
		const raw = localStorage.getItem(keyOf(cardId));
		if (!raw) return null;
		const parsed: unknown = JSON.parse(raw);
		if (typeof parsed !== 'object' || parsed === null) return null;
		return typeof (parsed as DraftBackup).savedAt === 'number' ? (parsed as DraftBackup) : null;
	} catch {
		return null;
	}
}

export function clearBackup(cardId: number) {
	localStorage.removeItem(keyOf(cardId));
}

/** 备份比数据库记录新、且内容确实不同时，才提示恢复。 */
export function shouldOfferRestore(
	backup: DraftBackup | null,
	card: { title: string | null; body: string | null; updatedAt: number }
): backup is DraftBackup {
	if (!backup || backup.savedAt <= card.updatedAt) return false;
	return backup.title !== card.title || backup.body !== card.body;
}
