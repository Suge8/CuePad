import { stablePartition } from './reorder';

export const ACTIVE_PROJECT_KEY = 'cuepad:active-project';
export const INBOX_STORAGE_VALUE = 'inbox';

export type ProjectId = number | null;

type ProjectOrderItem = { id: number; sortOrder: number; isPinned: boolean };
type CardProjectItem = { projectId: number | null };

export function parseStoredProjectId(value: string | null): ProjectId | undefined {
	if (value === INBOX_STORAGE_VALUE) return null;
	if (!value || !/^[1-9]\d*$/.test(value)) return undefined;
	const id = Number(value);
	return Number.isSafeInteger(id) ? id : undefined;
}

export function orderedProjects<Project extends ProjectOrderItem>(projects: Project[]): Project[] {
	const byBaseOrder = [...projects].sort(
		(left, right) => left.sortOrder - right.sortOrder || left.id - right.id
	);
	return stablePartition(byBaseOrder, (project) => project.isPinned);
}

export function resolveActiveProjectId(
	projects: ProjectOrderItem[],
	cards: CardProjectItem[],
	storedProjectId: ProjectId | undefined
): ProjectId {
	if (storedProjectId === null) return null;
	if (
		typeof storedProjectId === 'number' &&
		projects.some((project) => project.id === storedProjectId)
	) {
		return storedProjectId;
	}
	if (cards.some((card) => card.projectId === null)) return null;
	return orderedProjects(projects)[0]?.id ?? null;
}

export function adjacentProjectId(
	projects: ProjectOrderItem[],
	deletedProjectId: number
): ProjectId {
	const projectIds: ProjectId[] = [null, ...orderedProjects(projects).map((project) => project.id)];
	const deletedIndex = projectIds.indexOf(deletedProjectId);
	if (deletedIndex === -1) return null;
	return projectIds[deletedIndex + 1] ?? projectIds[deletedIndex - 1] ?? null;
}
