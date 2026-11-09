// 真实 Pi 发送交错验收：仅延长公开认证预检／扩展事件，不改生产队列。
// 写 <agent>/queue-gates/<阶段>.arm，等 held 后执行停止，再写 release；SDK 队列只经公开 followUp API 填入。
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { appears, onAppear } from "./gate.ts";

const directory = join(process.env.PI_CODING_AGENT_DIR!, "queue-gates");
const ceilingMs = 30_000;

async function hold(stage: string) {
	const arm = join(directory, `${stage}.arm`);
	if (!existsSync(arm)) return;
	rmSync(arm);
	writeFileSync(join(directory, `${stage}.held`), "");
	const released = await appears(join(directory, `${stage}.release`), ceilingMs);
	writeFileSync(join(directory, `${stage}.${released ? "released" : "ceiling"}`), "");
}

export default function (pi: any) {
	mkdirSync(directory, { recursive: true });
	pi.on("session_start", (_: any, ctx: any) => {
		const original = ctx.modelRegistry.getApiKeyAndHeaders.bind(ctx.modelRegistry);
		ctx.modelRegistry.getApiKeyAndHeaders = async (...args: any[]) => { await hold("preflight"); return original(...args); };
		const stop = onAppear(join(directory, "sdk.arm"), () => {
			pi.sendUserMessage("QUEUE-B WORK-B", { deliverAs: "followUp" }); // 假模型的剧本照 WORK-B 起 B 的工具（RealPiQueueTests.script）
			setImmediate(() => writeFileSync(join(directory, ctx.hasPendingMessages() ? "sdk.pending" : "sdk.empty"), ""));
		});
		pi.on("session_shutdown", stop);
	});
	pi.on("input", async (event: any) => { if (event.text?.includes("QUEUE-B")) await hold("starting"); });
	pi.on("agent_end", async () => { await hold("pending"); });
}
