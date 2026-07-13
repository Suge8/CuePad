import type { SqlValue } from './client';
import { mapCard, type CardRow } from './rows';
import {
	assign,
	assignOptional,
	createDeleteBatchId,
	insertedId,
	nowMs,
	optionalBoolean,
	selectOne,
	toSqlBoolean,
	where,
	type RepositoryContext
} from './repository-context';
import type { Card, CreateCardInput, DeleteResult, ListCardsOptions, UpdateCardInput } from './types';

export async function createCard(context: RepositoryContext, input: CreateCardInput = {}): Promise<Card> {
	const database = await context.loadDatabase();
	const timestamp = nowMs();
	const result = await database.execute(
		`INSERT INTO cards (project_id, title, body, sort_order, is_favorite, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $6)`,
		[
			input.projectId ?? null,
			input.title ?? null,
			input.body ?? null,
			input.sortOrder ?? 0,
			toSqlBoolean(input.isFavorite ?? false),
			timestamp
		]
	);

	return requireCard(context, insertedId(result), true);
}

export async function getCard(context: RepositoryContext, id: number, includeDeleted = false): Promise<Card | null> {
	const database = await context.loadDatabase();
	const deletedFilter = includeDeleted ? '' : ' AND deleted_at IS NULL';
	const row = await selectOne<CardRow>(database, `SELECT * FROM cards WHERE id = $1${deletedFilter}`, [id]);
	return row ? mapCard(row) : null;
}

export async function listCards(context: RepositoryContext, options: ListCardsOptions = {}): Promise<Card[]> {
	const database = await context.loadDatabase();
	const conditions: string[] = [];
	const values: SqlValue[] = [];
	if (!options.includeDeleted) conditions.push('deleted_at IS NULL');
	if (options.favoriteOnly) conditions.push('is_favorite = 1');
	if (options.projectId === null) conditions.push('project_id IS NULL');
	if (typeof options.projectId === 'number') {
		values.push(options.projectId);
		conditions.push(`project_id = $${values.length}`);
	}

	const rows = await database.select<CardRow[]>(
		`SELECT * FROM cards ${where(conditions)} ORDER BY sort_order, id`,
		values
	);
	return rows.map(mapCard);
}

export async function updateCard(
	context: RepositoryContext,
	id: number,
	input: UpdateCardInput
): Promise<Card | null> {
	const assignments: string[] = [];
	const values: SqlValue[] = [];
	assignOptional(assignments, values, 'project_id', input.projectId);
	assignOptional(assignments, values, 'title', input.title);
	assignOptional(assignments, values, 'body', input.body);
	assignOptional(assignments, values, 'sort_order', input.sortOrder);
	assignOptional(assignments, values, 'is_favorite', optionalBoolean(input.isFavorite));
	assignOptional(assignments, values, 'numbering', input.numbering);
	if (assignments.length === 0) return getCard(context, id, true);

	const database = await context.loadDatabase();
	assign(assignments, values, 'updated_at', nowMs());
	values.push(id);
	await database.execute(`UPDATE cards SET ${assignments.join(', ')} WHERE id = $${values.length}`, values);
	return getCard(context, id, true);
}

export async function softDeleteCard(context: RepositoryContext, id: number): Promise<DeleteResult | null> {
	const database = await context.loadDatabase();
	const deletedAt = nowMs();
	const batchId = createDeleteBatchId();
	const result = await database.execute(
		`UPDATE cards
		 SET deleted_at = $1, delete_batch_id = $2, delete_source = 'card', delete_source_id = id, updated_at = $1
		 WHERE id = $3 AND deleted_at IS NULL`,
		[deletedAt, batchId, id]
	);
	return result.rowsAffected > 0 ? { batchId, deletedAt } : null;
}

export async function restoreCard(context: RepositoryContext, id: number): Promise<Card | null> {
	const database = await context.loadDatabase();
	// A card restored into a still-deleted project would become invisible;
	// move it to the inbox instead.
	await database.execute(
		`UPDATE cards
		 SET deleted_at = NULL, delete_batch_id = NULL, delete_source = NULL, delete_source_id = NULL,
		     project_id = CASE
		       WHEN project_id IN (SELECT id FROM projects WHERE deleted_at IS NOT NULL) THEN NULL
		       ELSE project_id
		     END,
		     updated_at = $1
		 WHERE id = $2`,
		[nowMs(), id]
	);
	return getCard(context, id);
}

export async function deleteCardPermanently(context: RepositoryContext, id: number): Promise<void> {
	const database = await context.loadDatabase();
	await database.execute(`DELETE FROM cards WHERE id = $1`, [id]);
}

export async function reorderCards(context: RepositoryContext, orderedIds: number[]): Promise<void> {
	if (orderedIds.length === 0) return;
	const database = await context.loadDatabase();
	const timestamp = nowMs();
	await database.executeBatch(
		orderedIds.map((id, index) => ({
			query: `UPDATE cards SET sort_order = $1, updated_at = $2 WHERE id = $3`,
			bindValues: [index, timestamp, id]
		}))
	);
}

async function requireCard(context: RepositoryContext, id: number, includeDeleted = false): Promise<Card> {
	const card = await getCard(context, id, includeDeleted);
	if (!card) throw new Error(`Card ${id} was not found.`);
	return card;
}
