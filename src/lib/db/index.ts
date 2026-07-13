import { getCuePadDatabase } from './connection';
import { createCuePadRepository } from './repository';

export const cuePadRepository = createCuePadRepository(getCuePadDatabase);

export { CUEPAD_DATABASE_URL } from './client';
export { getCuePadDatabase } from './connection';
export { createCuePadRepository } from './repository';
export type { CuePadRepository } from './repository';
export { EMPTY_SEARCH_RESULTS } from './search';
export type { SearchOptions, SearchResults } from './search';
export { INBOX_PROJECT } from './types';
export type * from './types';
