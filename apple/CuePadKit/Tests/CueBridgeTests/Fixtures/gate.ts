// 测试闸（queue-gates.ts、settle-gate.ts）共用的"等文件出现"。逐 10 毫秒查一次，不用 fs.watch：macOS 上它经 FSEvents 投递，
// 文件系统一忙就晚到超过 10 秒或不来（并行灌写文件时实测：放行文件已在、闸仍停着，测试那头 10 秒的确认先超时）。
import { existsSync, rmSync } from "node:fs";

/** 等 `path` 出现；到 `ceilingMs` 还没有就答 false。 */
export function appears(path: string, ceilingMs: number): Promise<boolean> {
	const deadline = Date.now() + ceilingMs;
	return new Promise((resolve) => {
		const tick = setInterval(() => {
			const there = existsSync(path);
			if (!there && Date.now() < deadline) return;
			clearInterval(tick);
			resolve(there);
		}, 10);
	});
}

/** `path` 每出现一次就删掉它、调一次 `fire`；返回停止的函数。 */
export function onAppear(path: string, fire: () => void): () => void {
	const tick = setInterval(() => {
		if (!existsSync(path)) return;
		rmSync(path);
		fire();
	}, 10);
	tick.unref();
	return () => clearInterval(tick);
}
