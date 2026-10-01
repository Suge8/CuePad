// 布局压力场景用的离线假模型（scripts/pi-real-churn.py 加载）：零网络、结果确定。
// 最后一条用户消息里的标记决定行为：[[slow]] 先等 1.5 秒（制造"思考中"窗口），[[fail]] 以出错结束，其余回一句 OK。
// 上下文里没有用户消息的调用（Pi 自己发起的）直接回一句 OK。不调用工具，不碰工作目录。
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export default function (pi: any) {
	pi.registerProvider("fake", {
		baseUrl: "http://127.0.0.1:1",
		apiKey: "fake",
		api: "fake-api",
		models: [{ id: "echo", name: "Echo", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 4096 }],
		streamSimple(model: any, context: any) {
			const stream = createAssistantMessageEventStream();
			(async () => {
				const msg: any = { role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id, usage, stopReason: "stop", timestamp: Date.now() };
				const lastUser = [...context.messages].reverse().find((m: any) => m.role === "user");
				const content = lastUser?.content ?? "";
				const text = typeof content === "string" ? content : content.filter((p: any) => p.type === "text").map((p: any) => p.text).join("\n");

				if (text.includes("[[slow]]")) await sleep(1500);
				stream.push({ type: "start", partial: msg });
				if (text.includes("[[fail]]")) {
					msg.stopReason = "error";
					msg.errorMessage = "402 Payment Required — insufficient credits for this request";
					stream.push({ type: "error", reason: "error", error: msg });
					stream.end();
					return;
				}
				msg.content.push({ type: "text", text: "OK" });
				stream.push({ type: "text_start", contentIndex: 0, partial: msg });
				stream.push({ type: "text_delta", contentIndex: 0, delta: "OK", partial: msg });
				stream.push({ type: "text_end", contentIndex: 0, content: "OK", partial: msg });
				stream.push({ type: "done", reason: "stop", message: msg });
				stream.end();
			})();
			return stream;
		},
	});
}
