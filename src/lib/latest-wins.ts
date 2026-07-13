/**
 * 「最新请求胜出」守卫：异步结果返回后，只有仍是最新一次请求时才允许写回状态，
 * 丢弃乱序到达的旧响应。用于切卡加载标签、搜索等竞态场景。
 */
export function createLatestWins() {
	let sequence = 0;
	return {
		/** 开始一次新请求，返回其票据 */
		next(): number {
			sequence += 1;
			return sequence;
		},
		/** 该票据是否仍是最新请求 */
		isCurrent(ticket: number): boolean {
			return ticket === sequence;
		}
	};
}
