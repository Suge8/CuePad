/** 异步写回只提交本次 patch；完整数据库快照不得覆盖请求期间产生的新 UI 状态。 */
export function mergePersistedPatch<Entity extends { updatedAt: number }>(
	current: Entity,
	persisted: Entity,
	patch: Partial<Entity>
): Entity {
	const committed = Object.fromEntries(
		Object.entries(patch).filter(([, value]) => value !== undefined)
	) as Partial<Entity>;
	return {
		...current,
		...committed,
		updatedAt: Math.max(current.updatedAt, persisted.updatedAt)
	};
}
