import { describe, expect, test } from 'bun:test';
import { buildCardSearch, buildProjectSearch, toLikePattern } from '../src/lib/db/search';

describe('toLikePattern', () => {
	test('wraps plain terms with %', () => {
		expect(toLikePattern('draft')).toBe('%draft%');
	});

	test('escapes % and _ so they match literally', () => {
		expect(toLikePattern('50%')).toBe('%50\\%%');
		expect(toLikePattern('a_b')).toBe('%a\\_b%');
	});

	test('escapes backslash itself', () => {
		expect(toLikePattern('a\\b')).toBe('%a\\\\b%');
	});
});

describe('buildProjectSearch', () => {
	test('binds the pattern and excludes deleted rows by default', () => {
		const statement = buildProjectSearch('work');
		expect(statement).not.toBeNull();
		expect(statement?.query).toContain('deleted_at IS NULL');
		expect(statement?.query).toContain("ESCAPE '\\'");
		expect(statement?.bindValues).toEqual(['%work%']);
	});

	test('targets only deleted rows for trash search', () => {
		const statement = buildProjectSearch('work', { deleted: true });
		expect(statement?.query).toContain('deleted_at IS NOT NULL');
	});

	test('returns null for empty or whitespace-only terms', () => {
		expect(buildProjectSearch('')).toBeNull();
		expect(buildProjectSearch('   ')).toBeNull();
	});
});

describe('buildCardSearch', () => {
	test('binds one escaped pattern per matched column', () => {
		const statement = buildCardSearch('50%_off');
		expect(statement).not.toBeNull();
		expect(statement?.query).toContain('cards.deleted_at IS NULL');
		expect(statement?.query).toContain('cards.title LIKE $1');
		expect(statement?.query).toContain('cards.body LIKE $2');
		expect(statement?.query).toContain('tags.name LIKE $3');
		expect(statement?.bindValues).toEqual(['%50\\%\\_off%', '%50\\%\\_off%', '%50\\%\\_off%']);
	});

	test('targets only deleted cards for trash search', () => {
		const statement = buildCardSearch('draft', { deleted: true });
		expect(statement?.query).toContain('cards.deleted_at IS NOT NULL');
	});

	test('returns null for empty or whitespace-only terms', () => {
		expect(buildCardSearch('')).toBeNull();
		expect(buildCardSearch('  \t ')).toBeNull();
	});
});
