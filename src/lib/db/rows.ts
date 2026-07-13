import { decodeSettingValue } from './settings-codec';
import type { AppSetting, Card, CardNumbering, DeleteSource, Project, Tag, Task } from './types';

export interface ProjectRow {
	id: number;
	name: string | null;
	icon: string | null;
	color: string;
	sort_order: number;
	is_pinned: number;
	deleted_at: number | null;
	delete_batch_id: string | null;
	delete_source: DeleteSource | null;
	delete_source_id: number | null;
	created_at: number;
	updated_at: number;
}

export interface CardRow {
	id: number;
	project_id: number | null;
	title: string | null;
	body: string | null;
	sort_order: number;
	is_favorite: number;
	numbering: CardNumbering;
	deleted_at: number | null;
	delete_batch_id: string | null;
	delete_source: DeleteSource | null;
	delete_source_id: number | null;
	created_at: number;
	updated_at: number;
}

export interface TagRow {
	id: number;
	name: string;
	color: string | null;
	created_at: number;
	updated_at: number;
}

export interface TaskRow {
	id: number;
	content: string;
	project_id: number | null;
	sort_order: number;
	completed_at: number | null;
	created_at: number;
	updated_at: number;
}

export interface AppSettingRow {
	key: string;
	value: string;
	created_at: number;
	updated_at: number;
}

export function mapProject(row: ProjectRow): Project {
	return {
		kind: 'project',
		id: row.id,
		name: row.name,
		icon: row.icon,
		color: row.color,
		sortOrder: row.sort_order,
		isPinned: row.is_pinned === 1,
		deletedAt: row.deleted_at,
		deleteBatchId: row.delete_batch_id,
		deleteSource: row.delete_source,
		deleteSourceId: row.delete_source_id,
		createdAt: row.created_at,
		updatedAt: row.updated_at
	};
}

export function mapCard(row: CardRow): Card {
	return {
		id: row.id,
		projectId: row.project_id,
		title: row.title,
		body: row.body,
		sortOrder: row.sort_order,
		isFavorite: row.is_favorite === 1,
		numbering: row.numbering,
		deletedAt: row.deleted_at,
		deleteBatchId: row.delete_batch_id,
		deleteSource: row.delete_source,
		deleteSourceId: row.delete_source_id,
		createdAt: row.created_at,
		updatedAt: row.updated_at
	};
}

export function mapTag(row: TagRow): Tag {
	return {
		id: row.id,
		name: row.name,
		color: row.color,
		createdAt: row.created_at,
		updatedAt: row.updated_at
	};
}

export function mapTask(row: TaskRow): Task {
	return {
		id: row.id,
		content: row.content,
		projectId: row.project_id,
		sortOrder: row.sort_order,
		completedAt: row.completed_at,
		createdAt: row.created_at,
		updatedAt: row.updated_at
	};
}

export function mapSetting(row: AppSettingRow): AppSetting {
	return {
		key: row.key,
		value: decodeSettingValue(row.key, row.value),
		createdAt: row.created_at,
		updatedAt: row.updated_at
	};
}
