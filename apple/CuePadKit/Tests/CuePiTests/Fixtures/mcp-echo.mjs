// 最小的 stdio MCP 替身：握手（2025-11-25 / 2025-06-18）、tools/list、一个 echo 工具与一个 pick 工具。
// 每次 echo 调用把参数追加到环境变量 MCP_ECHO_LOG 指向的文件（一行一条），作为"运行时确实调到了它"的证据。
// pick 向客户端要一个选择（elicitation/create，表单只有一个枚举字段 drink），把收到的答复作为结果返回。
import { appendFileSync } from "node:fs";

const versions = ["2025-11-25", "2025-06-18"];
const log = process.env.MCP_ECHO_LOG;
const echo = {
  name: "echo",
  description: "Echo the given text back, prefixed with 'echo:'.",
  inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
  annotations: { readOnlyHint: true },
};

const pick = {
  name: "pick",
  description: "Ask the user which drink they want and return their answer.",
  inputSchema: { type: "object", properties: {} },
};
let nextRequest = 1;
const waiting = new Map();

const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
const fail = (id, code, message) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");

function handle({ id, method, params, result }) {
  if (method === undefined) return waiting.get(id)?.(result ?? { action: "error" }); // 客户端对我们请求的答复
  if (id === undefined) return; // 通知（notifications/initialized 等）不回
  switch (method) {
    case "initialize": {
      const asked = params?.protocolVersion;
      return reply(id, {
        protocolVersion: versions.includes(asked) ? asked : versions[0],
        capabilities: { tools: {} },
        serverInfo: { name: "cuepad-echo", version: "1.0.0" },
      });
    }
    case "ping": return reply(id, {});
    case "tools/list": return reply(id, { tools: [echo, pick] });
    case "tools/call": {
      if (params?.name === "pick") {
        const ask = nextRequest++;
        waiting.set(ask, (answer) => reply(id, { content: [{ type: "text", text: `picked:${JSON.stringify(answer)}` }], isError: false }));
        return process.stdout.write(JSON.stringify({
          jsonrpc: "2.0", id: ask, method: "elicitation/create",
          params: { message: "喝什么？", requestedSchema: { type: "object", properties: { drink: { type: "string", title: "饮料", enum: ["茶", "咖啡"] } }, required: ["drink"] } },
        }) + "\n");
      }
      if (params?.name !== "echo") return fail(id, -32602, `unknown tool: ${params?.name}`);
      const text = String(params.arguments?.text ?? "");
      if (log) appendFileSync(log, text + "\n");
      return reply(id, { content: [{ type: "text", text: `echo:${text}` }], isError: false });
    }
    default: return fail(id, -32601, `method not found: ${method}`);
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (line) handle(JSON.parse(line));
  }
});
process.stdin.on("end", () => process.exit(0));
