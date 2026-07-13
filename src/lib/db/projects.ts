import type { SqlValue } from './client';
import { mapProject, type ProjectRow } from './rows';
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
import type { CreateProjectInput, DeleteResult, ListProjectsOptions, Project, UpdateProjectInput } from './types';

export async function createProject(context: RepositoryContext, input: CreateProjectInput): Promise<Project> {
	const database = await context.loadDatabase();
	const timestamp = nowMs();
	const result = await database.execute(
		`INSERT INTO projects (name, icon, color, sort_order, is_pinned, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $6)`,
		[
			input.name ?? null,
			input.icon ?? null,
			input.color,
			input.sortOrder ?? 0,
			toSqlBoolean(input.isPinned ?? false),
			timestamp
		]
	);

	return requireProject(context, insertedId(result), true);
}

export async function getProject(context: RepositoryContext, id: number, includeDeleted = false): Promise<Project | null> {
	const database = await context.loadDatabase();
	const deletedFilter = includeDeleted ? '' : ' AND deleted_at IS NULL';
	const row = await selectOne<ProjectRow>(database, `SELECT * FROM projects WHERE id = $1${deletedFilter}`, [id]);
	return row ? mapProject(row) : null;
}

export async function listProjects(
	context: RepositoryContext,
	options: ListProjectsOptions = {}
): Promise<Project[]> {
	const database = await context.loadDatabase();
	const conditions: string[] = [];
	const values: SqlValue[] = [];
	if (!options.includeDeleted) conditions.push('deleted_at IS NULL');
	if (options.pinnedOnly) conditions.push('is_pinned = 1');

	const rows = await database.select<ProjectRow[]>(
		`SELECT * FROM projects ${where(conditions)} ORDER BY sort_order, id`,
		values
	);
	return rows.map(mapProject);
}

export async function updateProject(
	context: RepositoryContext,
	id: number,
	input: UpdateProjectInput
): Promise<Project | null> {
	const assignments: string[] = [];
	const values: SqlValue[] = [];
	assignOptional(assignments, values, 'name', input.name);
	assignOptional(assignments, values, 'icon', input.icon);
	assignOptional(assignments, values, 'color', input.color);
	assignOptional(assignments, values, 'sort_order', input.sortOrder);
	assignOptional(assignments, values, 'is_pinned', optionalBoolean(input.isPinned));
	if (assignments.length === 0) return getProject(context, id, true);

	const database = await context.loadDatabase();
	assign(assignments, values, 'updated_at', nowMs());
	values.push(id);
	await database.execute(`UPDATE projects SET ${assignments.join(', ')} WHERE id = $${values.length}`, values);
	return getProject(context, id, true);
}

export function setProjectPinned(
	context: RepositoryContext,
	id: number,
	isPinned: boolean
): Promise<Project | null> {
	return updateProject(context, id, { isPinned });
}

export async function softDeleteProject(context: RepositoryContext, id: number): Promise<DeleteResult | null> {
	const project = await getProject(context, id);
	if (!project) return null;

	const database = await context.loadDatabase();
	const deletedAt = nowMs();
	const batchId = createDeleteBatchId();
	await database.executeBatch([
		{
			query: `UPDATE projects
				SET deleted_at = $1, delete_batch_id = $2, delete_source = 'project', delete_source_id = id, updated_at = $1
				WHERE id = $3 AND deleted_at IS NULL`,
			bindValues: [deletedAt, batchId, id]
		},
		{
			query: `UPDATE cards
				SET deleted_at = $1, delete_batch_id = $2, delete_source = 'project', delete_source_id = $3, updated_at = $1
				WHERE project_id = $3 AND deleted_at IS NULL`,
			bindValues: [deletedAt, batchId, id]
		}
	]);
	return { batchId, deletedAt };
}

export async function restoreProject(context: RepositoryContext, id: number): Promise<Project | null> {
	const project = await getProject(context, id, true);
	if (!project?.deletedAt || !project.deleteBatchId) return project;

	const database = await context.loadDatabase();
	const timestamp = nowMs();
	await database.executeBatch([
		{
			query: `UPDATE projects
				SET deleted_at = NULL, delete_batch_id = NULL, delete_source = NULL, delete_source_id = NULL, updated_at = $1
				WHERE id = $2`,
			bindValues: [timestamp, id]
		},
		{
			query: `UPDATE cards
				SET deleted_at = NULL, delete_batch_id = NULL, delete_source = NULL, delete_source_id = NULL, updated_at = $1
				WHERE project_id = $2 AND delete_batch_id = $3 AND delete_source = 'project' AND delete_source_id = $2`,
			bindValues: [timestamp, id, project.deleteBatchId]
		}
	]);
	return getProject(context, id);
}

export async function deleteProjectPermanently(context: RepositoryContext, id: number): Promise<void> {
	const project = await getProject(context, id, true);
	if (!project?.deletedAt) return;

	const database = await context.loadDatabase();
	await database.executeBatch([
		{
			query: `DELETE FROM cards
				WHERE delete_batch_id = $1 AND delete_source = 'project' AND delete_source_id = $2`,
			bindValues: [project.deleteBatchId, id]
		},
		{ query: `DELETE FROM projects WHERE id = $1`, bindValues: [id] }
	]);
}

export async function reorderProjects(context: RepositoryContext, orderedIds: number[]): Promise<void> {
	if (orderedIds.length === 0) return;
	const database = await context.loadDatabase();
	const timestamp = nowMs();
	await database.executeBatch(
		orderedIds.map((id, index) => ({
			query: `UPDATE projects SET sort_order = $1, updated_at = $2 WHERE id = $3`,
			bindValues: [index, timestamp, id]
		}))
	);
}

async function requireProject(context: RepositoryContext, id: number, includeDeleted = false): Promise<Project> {
	const project = await getProject(context, id, includeDeleted);
	if (!project) throw new Error(`Project ${id} was not found.`);
	return project;
}
