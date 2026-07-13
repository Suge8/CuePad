import { listCards } from './cards';
import { listProjects } from './projects';
import type { RepositoryContext } from './repository-context';
import type { TrashSnapshot } from './types';

export async function listTrash(context: RepositoryContext): Promise<TrashSnapshot> {
	const [projects, cards] = await Promise.all([
		listProjects(context, { includeDeleted: true }).then((items) => items.filter((item) => item.deletedAt)),
		listCards(context, { includeDeleted: true }).then((items) => items.filter((item) => item.deletedAt))
	]);
	return { projects, cards };
}

/** 清空回收站：硬删所有软删除的卡片与项目（同一事务） */
export async function emptyTrash(context: RepositoryContext): Promise<void> {
	const database = await context.loadDatabase();
	await database.executeBatch([
		{ query: `DELETE FROM cards WHERE deleted_at IS NOT NULL`, bindValues: [] },
		{ query: `DELETE FROM projects WHERE deleted_at IS NOT NULL`, bindValues: [] }
	]);
}
