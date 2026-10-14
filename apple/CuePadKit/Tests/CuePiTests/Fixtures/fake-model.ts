// 测试用假模型：真实 Pi + 真实桥扩展，零网络、结果确定。
// 最后一条 user 文字里的标记决定行为（请求被中止时以 aborted 结束）：
//   [[slow]]      流式输出前停住，直到测试放行（制造"正忙"窗口；见下"停住与放行"）
//   [[fail]]      以 error 结束
//   [[abort-as-error]] 请求被中止时以 error（"The operation was aborted."）结束，像 Pi 1.2 的 openai-codex 在工具被中止后的那次请求
//   [[tool:CMD]]  先发起 bash 工具调用（CMD 里的字面 \n 会变成换行），收到工具结果后回复 TOOL_DONE
//   [[write:PATH]] 先发起 write 工具调用（写 PATH），收到工具结果后回复 TOOL_DONE
//   [[subagent:NAME]] 先调用 FireCode 的 subagents 工具开一个子代理（任务"[[slow]] 子任务"），收到工具结果后回复 TOOL_DONE
//   [[overflow]]  上下文里还没有压缩摘要时以"上下文溢出"的错误结束（Pi 随即压缩再重试），有了摘要照常回复
// 压缩摘要的请求（Pi 把要压缩的对话写成 <conversation> 或 # Conversation 开头的一条消息）里，对话带着：
//   [[slow-compact]] 给摘要前停住，直到测试放行（制造"正在压缩"的窗口，期间被中止以 aborted 结束）
//   [[fail-compact]] 以 error 结束（压缩失败）
// 停住与放行：不按时长等（机器负载高时测试自己的步骤会慢过任何固定窗口），由测试决定窗口多长。停住时在 <agent 目录>/fake-model-gate/ 下写
//   held-<pid>-<序号>；测试往同目录写 release-<任意名> 放行一次（一个文件放行一次停住，先放后停也算）；请求被中止时立即结束停住，不消耗放行。
// 其余：回复 "ECHO <文字> IMAGES[<mime>:<base64长度>,…]"，证明文字与图片都进了模型上下文。
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import { mkdirSync, readdirSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { join } from "node:path";

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const gateDirectory = () => join(process.env.PI_CODING_AGENT_DIR!, "fake-model-gate");
const holdCeiling = 30_000; // 测试异常退出时不让 Pi 永远停着
let holds = 0;

// 停住直到放行（取走一个 release 文件）或请求被中止。用目录变化事件等，不轮询。
async function hold(signal?: AbortSignal) {
	if (signal?.aborted) return;
	const dir = gateDirectory();
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, `held-${process.pid}-${++holds}`), "");
	await new Promise<void>((resolve) => {
		let finished = false;
		const finish = () => {
			if (finished) return;
			finished = true;
			watcher.close();
			clearTimeout(ceiling);
			signal?.removeEventListener("abort", finish);
			resolve();
		};
		const take = () => {
			for (const name of readdirSync(dir).filter((n) => n.startsWith("release-"))) {
				try {
					unlinkSync(join(dir, name)); // 只有取走文件的那一方放行
					finish();
					return;
				} catch {}
			}
		};
		const watcher = watch(dir, take);
		const ceiling = setTimeout(finish, holdCeiling);
		signal?.addEventListener("abort", finish);
		take();
	});
}

export default function (pi: any) {
	pi.registerProvider("fake", {
		baseUrl: "http://127.0.0.1:1",
		apiKey: "fake",
		api: "fake-api",
		models: [
			{ id: "echo", name: "Echo", reasoning: false, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 4096 },
			{ id: "echo-think", name: "Echo Think", reasoning: true, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 4096 },
			{ id: "echo-b", name: "Echo B", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 4096 },
		],
		streamSimple(model: any, context: any, options?: any) {
			const stream = createAssistantMessageEventStream();
			(async () => {
				const msg: any = { role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id, usage, stopReason: "stop", timestamp: Date.now() };
				const lastMessage = context.messages[context.messages.length - 1];
				const lastUser = [...context.messages].reverse().find((m: any) => m.role === "user");
				const parts = typeof lastUser.content === "string" ? [{ type: "text", text: lastUser.content }] : lastUser.content;
				const text = parts.filter((p: any) => p.type === "text").map((p: any) => p.text).join("\n");
				const images = parts.filter((p: any) => p.type === "image").map((p: any) => `${p.mimeType}:${p.data.length}`);

				const summarizing = text.startsWith("<conversation>\n") || text.startsWith("# Conversation\n");
				if (text.includes("[[slow]]") || (summarizing && text.includes("[[slow-compact]]"))) await hold(options?.signal);
				stream.push({ type: "start", partial: msg });

				// 与真实提供方一样：被中止（Esc、CuePad 的停止）就以 aborted 结束这次请求
				if (options?.signal?.aborted) {
					const asError = text.includes("[[abort-as-error]]");
					msg.stopReason = asError ? "error" : "aborted";
					msg.errorMessage = asError ? "The operation was aborted." : "Request was aborted";
					stream.push({ type: "error", reason: msg.stopReason, error: msg });
					stream.end();
					return;
				}

				const compacted = context.messages.some((m: any) => JSON.stringify(m.content).includes("compacted into the following summary"));
				const overflow = !summarizing && text.includes("[[overflow]]") && !compacted;
				if (overflow || (summarizing ? text.includes("[[fail-compact]]") : text.includes("[[fail]]"))) {
					msg.stopReason = "error";
					msg.errorMessage = overflow ? "prompt is too long: 120000 tokens > 100000 maximum" : "fake model failure";
					stream.push({ type: "error", reason: "error", error: msg });
					stream.end();
					return;
				}

				const bash = /\[\[tool:(.+?)\]\]/.exec(text);
				const write = /\[\[write:(.+?)\]\]/.exec(text);
				const sub = /\[\[subagent:(.+?)\]\]/.exec(text);
				const tool = bash ?? write ?? sub;
				if (tool && lastMessage.role !== "toolResult") {
					const call = sub
						? { type: "toolCall", id: "call_1", name: "subagents", arguments: { action: "start", worker: sub[1], role: "工程师", prompt: "[[slow]] 子任务" } }
						: bash
						? { type: "toolCall", id: "call_1", name: "bash", arguments: { command: bash[1].replaceAll("\\n", "\n") } }
						: { type: "toolCall", id: "call_1", name: "write", arguments: { path: write![1], content: "x" } };
					msg.content.push(call);
					msg.stopReason = "toolUse";
					stream.push({ type: "toolcall_start", contentIndex: 0, partial: msg });
					stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: call, partial: msg });
					stream.push({ type: "done", reason: "toolUse", message: msg });
					stream.end();
					return;
				}

				const reply = tool ? "TOOL_DONE" : `ECHO ${text} IMAGES[${images.join(",")}]`;
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
