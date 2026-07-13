declare module 'bun:sqlite' {
	type SqliteValue = string | number | null;

	interface RunResult {
		changes: number;
		lastInsertRowid: number;
	}

	interface Statement<Row = Record<string, unknown>> {
		run(...values: SqliteValue[]): RunResult;
		all(...values: SqliteValue[]): Row[];
	}

	export class Database {
		constructor(filename: string);
		exec(query: string): void;
		query<Row = Record<string, unknown>>(query: string): Statement<Row>;
		close(): void;
	}
}

declare module 'bun:test' {
	interface Expectation {
		not: Expectation;
		resolves: AsyncExpectation;
		rejects: AsyncExpectation;
		toBe(expected: unknown): void;
		toEqual(expected: unknown): void;
		toBeNull(): void;
		toContain(expected: string): void;
		toBeUndefined(): void;
		toHaveLength(length: number): void;
		toMatchObject(expected: unknown): void;
	}

	interface AsyncExpectation {
		toBeUndefined(): Promise<void>;
		toThrow(expected?: unknown): Promise<void>;
	}

	export function describe(name: string, run: () => void): void;
	export function test(name: string, run: () => void | Promise<void>): void;
	export function beforeEach(run: () => void | Promise<void>): void;
	export function expect(value: unknown): Expectation;
	export const mock: {
		module(name: string, factory: () => unknown): void;
	};
}
