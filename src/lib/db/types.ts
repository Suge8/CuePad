export type DeleteSource = 'project' | 'card';

export type SettingValue =
	| string
	| number
	| boolean
	| null
	| SettingValue[]
	| { [key: string]: SettingValue };

export type ThemeSetting = 'system' | 'light' | 'dark';

/** 卡片分块编号风格：复制排版与块头 badge 共用。 */
export type CardNumbering = 'none' | 'decimal' | 'alpha' | 'cjk';

export interface Project {
	kind: 'project';
	id: number;
	name: string | null;
	icon: string | null;
	color: string;
	sortOrder: number;
	isPinned: boolean;
	deletedAt: number | null;
	deleteBatchId: string | null;
	deleteSource: DeleteSource | null;
	deleteSourceId: number | null;
	createdAt: number;
	updatedAt: number;
}

export interface InboxProject {
	kind: 'inbox';
	id: null;
	name: 'Inbox';
	displayName: '未归档';
	color: string;
	isVirtual: true;
}

export const INBOX_PROJECT: InboxProject = {
	kind: 'inbox',
	id: null,
	name: 'Inbox',
	displayName: '未归档',
	color: '#e7e5e4',
	isVirtual: true
};

export type ProjectView = Project | InboxProject;

export interface Card {
	id: number;
	projectId: number | null;
	title: string | null;
	body: string | null;
	sortOrder: number;
	isFavorite: boolean;
	numbering: CardNumbering;
	deletedAt: number | null;
	deleteBatchId: string | null;
	deleteSource: DeleteSource | null;
	deleteSourceId: number | null;
	createdAt: number;
	updatedAt: number;
}

export interface Tag {
	id: number;
	name: string;
	color: string | null;
	createdAt: number;
	updatedAt: number;
}

export interface Task {
	id: number;
	content: string;
	projectId: number | null;
	sortOrder: number;
	completedAt: number | null;
	createdAt: number;
	updatedAt: number;
}

export interface AppSetting<T extends SettingValue = SettingValue> {
	key: string;
	value: T;
	createdAt: number;
	updatedAt: number;
}

export interface AppSettings {
	theme?: ThemeSetting;
	globalShortcut?: string | null;
	[key: string]: SettingValue | undefined;
}

export interface CreateProjectInput {
	color: string;
	name?: string | null;
	icon?: string | null;
	sortOrder?: number;
	isPinned?: boolean;
}

export interface UpdateProjectInput {
	color?: string;
	name?: string | null;
	icon?: string | null;
	sortOrder?: number;
	isPinned?: boolean;
}

export interface CreateCardInput {
	projectId?: number | null;
	title?: string | null;
	body?: string | null;
	sortOrder?: number;
	isFavorite?: boolean;
}

export interface UpdateCardInput {
	projectId?: number | null;
	title?: string | null;
	body?: string | null;
	sortOrder?: number;
	isFavorite?: boolean;
	numbering?: CardNumbering;
}

export interface CreateTaskInput {
	content: string;
	projectId?: number | null;
}

export interface UpdateTaskInput {
	content?: string;
	projectId?: number | null;
	completedAt?: number | null;
}

export interface ListProjectsOptions {
	includeDeleted?: boolean;
	pinnedOnly?: boolean;
}

export interface ListCardsOptions {
	projectId?: number | null;
	includeDeleted?: boolean;
	favoriteOnly?: boolean;
}

export interface TrashSnapshot {
	projects: Project[];
	cards: Card[];
}

export interface DeleteResult {
	batchId: string;
	deletedAt: number;
}
