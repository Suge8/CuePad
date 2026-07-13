export function stablePartition<Item>(items: Item[], first: (item: Item) => boolean): Item[] {
	const leading: Item[] = [];
	const trailing: Item[] = [];
	for (const item of items) (first(item) ? leading : trailing).push(item);
	return [...leading, ...trailing];
}

/**
 * 把一个展示分区的拖拽顺序写回基础序列中该分区原有的槽位。
 * 分区外元素及其槽位不动；无效/跨分区输入返回 null。
 */
export function mergePartitionOrder<Item extends { id: number }>(
	items: Item[],
	orderedPartitionIds: number[],
	inPartition: (item: Item) => boolean
): number[] | null {
	const partitionIds = items.filter(inPartition).map((item) => item.id);
	const partitionIdSet = new Set(partitionIds);
	if (
		orderedPartitionIds.length !== partitionIds.length ||
		new Set(orderedPartitionIds).size !== partitionIds.length ||
		orderedPartitionIds.some((id) => !partitionIdSet.has(id))
	) {
		return null;
	}

	let partitionIndex = 0;
	return items.map((item) =>
		inPartition(item) ? orderedPartitionIds[partitionIndex++] : item.id
	);
}

/**
 * 在同一列表内根据拖拽结果计算新的 id 顺序。
 * 返回 null 表示无需变更（拖到自己或位置无效）。
 */
export function reorderIds(
	items: { id: number }[],
	draggedId: number,
	targetId: number,
	position: 'before' | 'after' | null
): number[] | null {
	if (draggedId === targetId || position === null) return null;
	const ids = items.map((item) => item.id).filter((id) => id !== draggedId);
	const targetIndex = ids.indexOf(targetId);
	if (targetIndex === -1) return null;
	ids.splice(position === 'after' ? targetIndex + 1 : targetIndex, 0, draggedId);
	return ids;
}
