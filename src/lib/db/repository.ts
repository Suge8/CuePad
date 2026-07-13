import {
	createCard,
	deleteCardPermanently,
	getCard,
	listCards,
	reorderCards,
	restoreCard,
	softDeleteCard,
	updateCard
} from './cards';
import type { SqlDatabase } from './client';
import {
	createProject,
	deleteProjectPermanently,
	getProject,
	listProjects,
	reorderProjects,
	restoreProject,
	setProjectPinned,
	softDeleteProject,
	updateProject
} from './projects';
import type { RepositoryContext } from './repository-context';
import { searchContent } from './search';
import { getAppSetting, getSettings, setSetting } from './settings';
import { addTagToCard, createTag, listTags, listTagsForCard, removeTagFromCard, setTagColor } from './tags';
import { createTask, deleteTaskPermanently, listTasks, reorderTasks, updateTask } from './tasks';
import { emptyTrash, listTrash } from './trash';

export function createCuePadRepository(loadDatabase: () => Promise<SqlDatabase>) {
	const context: RepositoryContext = { loadDatabase };

	return {
		createProject: createProject.bind(null, context),
		getProject: getProject.bind(null, context),
		listProjects: listProjects.bind(null, context),
		updateProject: updateProject.bind(null, context),
		setProjectPinned: setProjectPinned.bind(null, context),
		softDeleteProject: softDeleteProject.bind(null, context),
		restoreProject: restoreProject.bind(null, context),
		deleteProjectPermanently: deleteProjectPermanently.bind(null, context),
		reorderProjects: reorderProjects.bind(null, context),
		createCard: createCard.bind(null, context),
		getCard: getCard.bind(null, context),
		listCards: listCards.bind(null, context),
		updateCard: updateCard.bind(null, context),
		softDeleteCard: softDeleteCard.bind(null, context),
		restoreCard: restoreCard.bind(null, context),
		deleteCardPermanently: deleteCardPermanently.bind(null, context),
		reorderCards: reorderCards.bind(null, context),
		createTag: createTag.bind(null, context),
		setTagColor: setTagColor.bind(null, context),
		listTags: listTags.bind(null, context),
		addTagToCard: addTagToCard.bind(null, context),
		removeTagFromCard: removeTagFromCard.bind(null, context),
		listTagsForCard: listTagsForCard.bind(null, context),
		createTask: createTask.bind(null, context),
		listTasks: listTasks.bind(null, context),
		updateTask: updateTask.bind(null, context),
		reorderTasks: reorderTasks.bind(null, context),
		deleteTaskPermanently: deleteTaskPermanently.bind(null, context),
		getAppSetting: getAppSetting.bind(null, context),
		getSettings: getSettings.bind(null, context),
		setSetting: setSetting.bind(null, context),
		listTrash: listTrash.bind(null, context),
		emptyTrash: emptyTrash.bind(null, context),
		searchContent: searchContent.bind(null, context)
	};
}

export type CuePadRepository = ReturnType<typeof createCuePadRepository>;
