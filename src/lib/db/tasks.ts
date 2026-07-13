import type { SqlValue } from './client';
import { mapTask, type TaskRow } from './rows';
import {
	assign,
	assignOptional,
	insertedId,
	nowMs,
	selectOne,
	type RepositoryContext
} from './repository-context';
import type { CreateTaskInput, Task, UpdateTaskInput } from './types';

export async function createTask(
	context: RepositoryContext,
	input: CreateTaskInput
): Promise<Task> {
	requireTaskContent(input.content);
	const database = await context.loadDatabase();
	const timestamp = nowMs();
	const result = await database.execute(
		`INSERT INTO tasks (content, project_id, sort_order, completed_at, created_at, updated_at)
		 SELECT $1, $2, COALESCE(MIN(sort_order) - 1, 0), NULL, $3, $3
		 FROM tasks WHERE completed_at IS NULL`,
		[input.content, input.projectId ?? null, timestamp]
	);
	return requireTask(context, insertedId(result));
}

export async function listTasks(context: RepositoryContext): Promise<Task[]> {
	const database = await context.loadDatabase();
	const rows = await database.select<TaskRow[]>(
		`SELECT * FROM tasks
		 ORDER BY
		   completed_at IS NOT NULL,
		   CASE WHEN completed_at IS NULL THEN sort_order END,
		   CASE WHEN completed_at IS NULL THEN id END,
		   completed_at DESC,
		   id DESC`
	);
	return rows.map(mapTask);
}

export async function updateTask(
	context: RepositoryContext,
	id: number,
	input: UpdateTaskInput
): Promise<Task | null> {
	if (input.content !== undefined) requireTaskContent(input.content);
	const assignments: string[] = [];
	const values: SqlValue[] = [];
	assignOptional(assignments, values, 'content', input.content);
	assignOptional(assignments, values, 'project_id', input.projectId);
	assignOptional(assignments, values, 'completed_at', input.completedAt);
	if (assignments.length === 0) return getTask(context, id);

	const database = await context.loadDatabase();
	assign(assignments, values, 'updated_at', nowMs());
	values.push(id);
	await database.execute(`UPDATE tasks SET ${assignments.join(', ')} WHERE id = $${values.length}`, values);
	return getTask(context, id);
}

export async function reorderTasks(
	context: RepositoryContext,
	orderedIds: number[]
): Promise<void> {
	const database = await context.loadDatabase();
	const baseOrder = await database.select<{ id: number; completed_at: number | null }[]>(
		`SELECT id, completed_at FROM tasks ORDER BY sort_order, id`
	);
	const activeIds = new Set(
		baseOrder.filter((task) => task.completed_at === null).map((task) => task.id)
	);
	if (
		orderedIds.length !== activeIds.size ||
		new Set(orderedIds).size !== orderedIds.length ||
		orderedIds.some((id) => !activeIds.has(id))
	) {
		throw new Error('Task order must contain every active task exactly once.');
	}
	if (orderedIds.length === 0) return;

	let activeIndex = 0;
	const mergedIds = baseOrder.map((task) =>
		task.completed_at === null ? orderedIds[activeIndex++] : task.id
	);
	const timestamp = nowMs();
	await database.executeBatch(
		mergedIds.map((id, index) => ({
			query: `UPDATE tasks SET sort_order = $1, updated_at = $2 WHERE id = $3`,
			bindValues: [index, timestamp, id]
		}))
	);
}

export async function deleteTaskPermanently(
	context: RepositoryContext,
	id: number
): Promise<void> {
	const database = await context.loadDatabase();
	await database.execute(`DELETE FROM tasks WHERE id = $1`, [id]);
}

function requireTaskContent(content: string) {
	if (!content.trim()) throw new Error('Task content must not be blank.');
}

async function getTask(context: RepositoryContext, id: number): Promise<Task | null> {
	const database = await context.loadDatabase();
	const row = await selectOne<TaskRow>(database, `SELECT * FROM tasks WHERE id = $1`, [id]);
	return row ? mapTask(row) : null;
}

async function requireTask(context: RepositoryContext, id: number): Promise<Task> {
	const task = await getTask(context, id);
	if (!task) throw new Error(`Task ${id} was not found.`);
	return task;
}
