import { mapTag, type TagRow } from './rows';
import { nowMs, selectOne, type RepositoryContext } from './repository-context';
import type { Tag } from './types';

export async function createTag(context: RepositoryContext, name: string): Promise<Tag> {
	const database = await context.loadDatabase();
	const timestamp = nowMs();
	await database.execute(
		`INSERT INTO tags (name, created_at, updated_at) VALUES ($1, $2, $2)
		 ON CONFLICT(name) DO NOTHING`,
		[name, timestamp]
	);
	const row = await selectOne<TagRow>(database, `SELECT * FROM tags WHERE name = $1`, [name]);
	if (!row) throw new Error(`Tag ${name} was not found.`);
	return mapTag(row);
}

export async function setTagColor(
	context: RepositoryContext,
	id: number,
	color: string | null
): Promise<Tag | null> {
	const database = await context.loadDatabase();
	await database.execute(`UPDATE tags SET color = $1, updated_at = $2 WHERE id = $3`, [
		color,
		nowMs(),
		id
	]);
	const row = await selectOne<TagRow>(database, `SELECT * FROM tags WHERE id = $1`, [id]);
	return row ? mapTag(row) : null;
}

export async function listTags(context: RepositoryContext): Promise<Tag[]> {
	const database = await context.loadDatabase();
	const rows = await database.select<TagRow[]>(`SELECT * FROM tags ORDER BY name`, []);
	return rows.map(mapTag);
}

export async function addTagToCard(context: RepositoryContext, cardId: number, tagId: number): Promise<void> {
	const database = await context.loadDatabase();
	await database.execute(
		`INSERT OR IGNORE INTO card_tags (card_id, tag_id, created_at) VALUES ($1, $2, $3)`,
		[cardId, tagId, nowMs()]
	);
}

export async function removeTagFromCard(context: RepositoryContext, cardId: number, tagId: number): Promise<void> {
	const database = await context.loadDatabase();
	await database.execute(`DELETE FROM card_tags WHERE card_id = $1 AND tag_id = $2`, [cardId, tagId]);
}

export async function listTagsForCard(context: RepositoryContext, cardId: number): Promise<Tag[]> {
	const database = await context.loadDatabase();
	const rows = await database.select<TagRow[]>(
		`SELECT tags.*
		 FROM tags JOIN card_tags ON card_tags.tag_id = tags.id
		 WHERE card_tags.card_id = $1
		 ORDER BY tags.name`,
		[cardId]
	);
	return rows.map(mapTag);
}
