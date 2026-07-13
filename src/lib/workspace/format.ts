const DAY_MS = 86_400_000;

export function formatTime(timestamp: number): string {
	const date = new Date(timestamp);
	const now = new Date();
	const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();

	if (timestamp >= startOfToday) {
		return date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
	}
	if (timestamp >= startOfToday - DAY_MS) return '昨天';
	if (date.getFullYear() === now.getFullYear()) {
		return `${date.getMonth() + 1}月${date.getDate()}日`;
	}
	return date.toLocaleDateString('zh-CN');
}
