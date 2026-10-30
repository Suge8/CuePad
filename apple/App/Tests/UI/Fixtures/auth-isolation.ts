import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import chatgpt from "./chatgpt.ts";

// Claude 授权服务由测试放行失败；事件门不依赖机器速度，也不访问真实服务。
export default async function (pi: any) {
	chatgpt(pi);
	const agent = process.env.PI_CODING_AGENT_DIR!;
	const failure = new Error("Claude authorization expired (synthetic)");
	const pending = new Set<(error: Error) => void>();
	const entered = new Set<http.ServerResponse>();
	let rejected = false;
	const server = http.createServer((request, response) => {
		switch (request.url) {
			case "/expire": {
				const file = path.join(agent, "auth.json");
				const credentials = JSON.parse(fs.readFileSync(file, "utf8"));
				credentials.anthropic.expires = 0;
				fs.writeFileSync(file, JSON.stringify(credentials));
				break;
			}
			case "/entered":
				if (pending.size > 0) break;
				entered.add(response);
				response.on("close", () => entered.delete(response));
				return;
			case "/reject":
				rejected = true;
				for (const reject of pending) reject(failure);
				pending.clear();
				break;
			default:
				response.writeHead(404).end();
				return;
		}
		response.end();
	});
	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	fs.writeFileSync(path.join(agent, "claude-auth-url"), `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`);
	pi.on("session_shutdown", () => { server.closeAllConnections(); server.close(); });
	pi.registerProvider("anthropic", {
		baseUrl: "http://127.0.0.1:1", api: "claude-auth-test",
		oauth: {
			name: "Claude Test",
			login: async () => { throw new Error("test never signs in"); },
			getApiKey: (credential: any) => credential.access,
			refreshToken: async () => {
				if (rejected) throw failure;
				return new Promise((_resolve, reject) => {
					pending.add(reject);
					for (const response of entered) response.end();
					entered.clear();
				});
			},
		},
		models: [{ id: "claude-test", name: "Claude Test", reasoning: false, input: ["text"],
			contextWindow: 100000, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
	});
}
