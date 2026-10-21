/**
 * Cue 的工具（task、tell、memory）在 Pi 里就叫服务给的名字。Pi 内置的 MCP 支持把工具一律命名成 mcp__<服务>__<工具>，
 * 而系统提示、工具说明与模型自己的习惯都写 memory recall、task start，模型常照着调不带前缀的名字，被 Pi 以
 * "Tool memory not found" 拒掉；所以不走内置的，由这个扩展当 MCP 客户端：加载时起 CuePad 的 MCP 服务（命令行是环境变量
 * CUEPAD_CUE_MCP 里的 JSON 数组，由 PiBrain 给，服务的其余环境随 Pi 进程继承），握手、取工具清单、照原名逐个登记，
 * 每次调用转成 tools/call；服务出错的结果抛出成工具出错。服务随运行时收（session_shutdown；开新会话时 Pi 重建运行时，
 * 会再加载一次、另起一个）。只说 CuePad 自己的 MCP 服务（`CueMCPServer`）用到的那点协议：一行一条 JSON-RPC。
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

interface Pending {
	resolve: (result: any) => void;
	reject: (error: Error) => void;
}

export default async function (pi: any) {
	const [command, ...args] = JSON.parse(process.env.CUEPAD_CUE_MCP ?? "[]") as string[];
	const server = spawn(command, args, { stdio: ["pipe", "pipe", "ignore"] });
	const pending = new Map<number, Pending>();
	let nextID = 0;
	const fail = (error: Error) => {
		for (const waiter of pending.values()) waiter.reject(error);
		pending.clear();
	};
	server.on("error", fail);
	server.on("exit", (code, signal) => fail(new Error(`CuePad 的工具服务退出了（${signal ?? code}）`)));
	server.stdin.on("error", () => {});
	createInterface({ input: server.stdout }).on("line", (line) => {
		let message: any;
		try {
			message = JSON.parse(line);
		} catch {
			return;
		}
		const waiter = pending.get(message.id);
		if (!waiter) return;
		pending.delete(message.id);
		if (message.error) waiter.reject(new Error(message.error.message));
		else waiter.resolve(message.result);
	});
	const send = (message: object) => server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
	const request = (method: string, params: object) =>
		new Promise<any>((resolve, reject) => {
			const id = ++nextID;
			pending.set(id, { resolve, reject });
			send({ id, method, params });
		});
	pi.on("session_shutdown", () => server.kill());

	await request("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "pi", version: "1" } });
	send({ method: "notifications/initialized" });
	const { tools } = await request("tools/list", {});
	for (const tool of tools) {
		pi.registerTool({
			name: tool.name,
			label: tool.name,
			description: tool.description ?? tool.name,
			parameters: { ...tool.inputSchema, type: "object", properties: tool.inputSchema?.properties ?? {} },
			async execute(_id: string, params: object) {
				const result = await request("tools/call", { name: tool.name, arguments: params ?? {} });
				const content = result.content ?? [];
				if (result.isError) throw new Error(content.map((block: any) => block.text ?? "").join("\n"));
				return { content, details: {} };
			},
		});
	}
}
