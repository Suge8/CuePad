// 测试用：Pi 报出这一轮收尾（agent_settled）之前停住一次，造出"Pi 已收尾、还没报出来"的那一刻——真实里是扩展处理收尾事件的那段等待，
// 这段里交来的话会开新的一轮，新一轮开始的事件先于上一轮的收尾到。
// 目录 <agent 目录>/settle-gate/：测试写 arm 后，下一次收尾删掉 arm、写 held，等到出现 release 才放行。不按时长等（同 fake-model.ts 的停住）。
// 放行时写 released；到了上限才放行的写 ceiling，测试见到它就失败（不悄悄停满上限再过）。
import { existsSync, mkdirSync, rmSync, watch, writeFileSync } from "node:fs";
import { join } from "node:path";

const holdCeiling = 30_000; // 测试异常退出时不让 Pi 永远停着

export default function (pi: any) {
	const dir = join(process.env.PI_CODING_AGENT_DIR!, "settle-gate");
	pi.on("agent_settled", async () => {
		if (!existsSync(join(dir, "arm"))) return;
		rmSync(join(dir, "arm"));
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, "held"), "");
		await new Promise<void>((resolve) => {
			const finish = (marker: string) => {
				watcher.close();
				clearTimeout(ceiling);
				writeFileSync(join(dir, marker), "");
				resolve();
			};
			const released = () => existsSync(join(dir, "release")) && finish("released");
			const watcher = watch(dir, released);
			const ceiling = setTimeout(() => finish("ceiling"), holdCeiling);
			released();
		});
	});
}
