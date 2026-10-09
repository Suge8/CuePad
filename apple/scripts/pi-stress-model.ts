// 布局压力场景用的离线假模型（scripts/pi-real-churn.py 加载）：零网络、结果确定。
// 最后一条用户消息里的标记决定行为：[[slow]] 先等 1.5 秒（制造"思考中"窗口），[[fail]] 以出错结束，
// [[tools]] 在工作目录里依次读文件、改文件、写文件、跑命令、再跑一条失败的命令（每步一个工具调用，做完回一句 TOOLS_DONE；
// 工具活动摘要的端到端验证用），其余回一句 OK。上下文里没有用户消息的调用（Pi 自己发起的）直接回一句 OK。
// 只有 [[tools]] 会碰工作目录（notes.txt、report.md）。
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// [[tools]] 的步骤：第 n 步是上一条用户消息之后的第 n 个工具调用
const toolSteps = [
	{ name: "read", arguments: { path: "notes.txt" } },
	{ name: "edit", arguments: { path: "notes.txt", edits: [{ oldText: "beta", newText: "beta\ngamma\ndelta" }] } },
	{ name: "write", arguments: { path: "report.md", content: "# 报告\n\n完成。\n" } },
	{ name: "bash", arguments: { command: "echo done && ls" } },
	{ name: "bash", arguments: { command: "cat missing-file.txt" } },
];

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
				const lastUserIndex = context.messages.lastIndexOf(lastUser);
				const done = context.messages.slice(lastUserIndex + 1).filter((m: any) => m.role === "toolResult").length;
				if (text.includes("[[tools]]") && done < toolSteps.length) {
					const call = { type: "toolCall", id: `call_${done + 1}`, ...toolSteps[done] };
					msg.content.push(call);
					msg.stopReason = "toolUse";
					stream.push({ type: "toolcall_start", contentIndex: 0, partial: msg });
					stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: call, partial: msg });
					stream.push({ type: "done", reason: "toolUse", message: msg });
					stream.end();
					return;
				}
				const reply = text.includes("[[tools]]") ? "TOOLS_DONE" : "OK";
				msg.content.push({ type: "text", text: reply });
				stream.push({ type: "text_start", contentIndex: 0, partial: msg });
				stream.push({ type: "text_delta", contentIndex: 0, delta: reply, partial: msg });
				stream.push({ type: "text_end", contentIndex: 0, content: reply, partial: msg });
				stream.push({ type: "done", reason: "stop", message: msg });
				stream.end();
			})();
			return stream;
		},
	});
}
