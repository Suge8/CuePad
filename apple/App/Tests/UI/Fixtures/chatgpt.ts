import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

// 外部模型服务替身；Pi、桥、历史、投送和库都走真实入口，绝不联网。
export default function (pi: any) {
	pi.registerProvider("openai", {
		baseUrl: "http://127.0.0.1:1", api: "chatgpt-test",
		oauth: {
			name: "ChatGPT Test",
			login: async () => { throw new Error("test never signs in"); },
			refreshToken: async () => { throw new Error("test never refreshes"); },
			getApiKey: (credential: any) => credential.access,
		},
		models: ["echo", "echo-next"].map((id) => ({ id, name: id, reasoning: false, input: ["text", "image"],
			contextWindow: 100000, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } })),
		streamSimple(model: any, context: any) {
			const stream = createAssistantMessageEventStream();
			queueMicrotask(() => {
				const last = context.messages.findLast((m: any) => m.role === "user");
				const text = typeof last.content === "string" ? last.content : last.content.filter((p: any) => p.type === "text").map((p: any) => p.text).join("");
				const stopReason = text.includes("[[length]]") ? "length" : text.includes("[[quota]]") || text.includes("[[403]]") ? "error" : "stop";
				const message: any = { role: "assistant", content: [{ type: "text", text: "PARTIAL_REPLY" }], api: model.api,
					provider: model.provider, model: model.id, stopReason, timestamp: Date.now(),
					usage: { input: 10, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 13, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
				stream.push({ type: "start", partial: message });
				stream.push({ type: "text_delta", contentIndex: 0, delta: "PARTIAL_REPLY", partial: message });
				if (stopReason === "error") {
					message.errorMessage = text.includes("[[403]]") ? '403 {"error":{"code":"permission_error","message":"App is not permitted"}}'
						: '{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"App usage limit reached"}}';
					stream.push({ type: "error", reason: "error", error: message });
				} else {
					stream.push({ type: "done", reason: stopReason, message });
				}
				stream.end();
			});
			return stream;
		},
	});
}
