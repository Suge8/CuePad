import type { SqlStatement } from './client';
import type { RepositoryContext } from './repository-context';
import { mapCard, mapProject, type CardRow, type ProjectRow } from './rows';
import type { Card, Project } from './types';

export interface SearchOptions {
	/** true = 只搜回收站（已删内容）；缺省只搜未删内容 */
	deleted?: boolean;
}

export interface SearchResults {
	projects: Project[];
	cards: Card[];
}

export const EMPTY_SEARCH_RESULTS: SearchResults = { projects: [], cards: [] };

const PROJECT_LIMIT = 10;
const CARD_LIMIT = 20;

/** 把用户输入转成按字面匹配的 LIKE 模式：转义 \ % _ 后包上 %…% */
export function toLikePattern(term: string): string {
	return `%${term.replace(/[\\%_]/g, (char) => `\\${char}`)}%`;
}

export function buildProjectSearch(term: string, options: SearchOptions = {}): SqlStatement | null {
	const trimmed = term.trim();
	if (!trimmed) return null;
	const deletedCondition = options.deleted ? 'deleted_at IS NOT NULL' : 'deleted_at IS NULL';
	return {
		query: `SELECT * FROM projects WHERE ${deletedCondition} AND name LIKE $1 ESCAPE '\\' ORDER BY sort_order, id LIMIT ${PROJECT_LIMIT}`,
		bindValues: [toLikePattern(trimmed)]
	};
}

/** 卡片按标题、正文、标签名匹配（标签经 card_tags 关联） */
export function buildCardSearch(term: string, options: SearchOptions = {}): SqlStatement | null {
	const trimmed = term.trim();
	if (!trimmed) return null;
	const deletedCondition = options.deleted
		? 'cards.deleted_at IS NOT NULL'
		: 'cards.deleted_at IS NULL';
	const pattern = toLikePattern(trimmed);
	return {
		query: `SELECT DISTINCT cards.* FROM cards
		 LEFT JOIN card_tags ON card_tags.card_id = cards.id
		 LEFT JOIN tags ON tags.id = card_tags.tag_id
		 WHERE ${deletedCondition}
		   AND (cards.title LIKE $1 ESCAPE '\\' OR cards.body LIKE $2 ESCAPE '\\' OR tags.name LIKE $3 ESCAPE '\\')
		 ORDER BY cards.updated_at DESC LIMIT ${CARD_LIMIT}`,
		bindValues: [pattern, pattern, pattern]
	};
}

export async function searchContent(
	context: RepositoryContext,
	term: string,
	options: SearchOptions = {}
): Promise<SearchResults> {
	const projectStatement = buildProjectSearch(term, options);
	const cardStatement = buildCardSearch(term, options);
	if (!projectStatement || !cardStatement) return EMPTY_SEARCH_RESULTS;

	const database = await context.loadDatabase();
	const [projectRows, cardRows] = await Promise.all([
		database.select<ProjectRow[]>(projectStatement.query, projectStatement.bindValues),
		database.select<CardRow[]>(cardStatement.query, cardStatement.bindValues)
	]);
	return { projects: projectRows.map(mapProject), cards: cardRows.map(mapCard) };
}
