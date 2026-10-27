// 测试用假模型：OpenAI 兼容的提供方（`POST /v1/chat/completions`，流式），给真 OpenCode 用，零网络、结果确定。
// 起法：node fake-openai.mjs；在 127.0.0.1 的空闲端口上听，标准输出第一行写 {"port": N}，标准输入关了就退出。
// 测试的话写成真模型也照做的英文；这里只认下面这些说法（按先后匹配最后一条用户消息），其余回 "ECHO <原话>"：
//   Call the echo tool with the text "T" … until you have made N calls   调 *_echo（参数 T），每拿到结果隔 1 秒拿上一次的结果再调，满 N 次回最后的结果
//   Use the shell tool to run exactly: CMD . Then reply W                  调 shell 跑 CMD，拿到结果后回 W
//   Use the subagent tool with agent A and description D, prompt: P. … reply W   调 subagent 派子代理，拿到结果后回 W
//   Use the question tool … header H, question Q with options X and Y. … reply with exactly the color …   调 question，拿到答案后回答案原文
//   Create a file named F                                                  调 write 写 F（大脑没有这个工具，OpenCode 回错），拿到结果后回一句话
//   Write the numbers …                                                    吐一行后停住，直到请求被中止（OpenCode 停下这一轮）；至多 30 秒
//   What is your codename?                                                 回系统提示里 "codename is X." 的 X
//   What color is this image?                                              回图（PNG）左上角像素最接近的颜色名
//   What word did I ask you to remember?                                   回更早的用户消息里 "Remember the word X" 的 X
//   reply with [exactly|only] [the [single] word] WORD（WORD 全大写）        回 WORD
// 不带工具的请求（起标题、压缩上下文的摘要）回一句固定的话。用量：输入按请求的消息估（每 4 个字符一个 token），缓存读 100。
import { createServer } from "node:http";
import { inflateSync } from "node:zlib";

const holdCeiling = 30_000;
const chainPause = 1_000;
const sleep = (ms, signal) => new Promise((resolve) => {
  const timer = setTimeout(resolve, ms);
  signal.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
});

const text = (content) => typeof content === "string" ? content
  : (content ?? []).filter((p) => p.type === "text").map((p) => p.text).join("\n");

// PNG 的第 0 行第 0 个像素不受行过滤影响（前面没有像素可参照），解压后跳过过滤字节就是它（只认 8 位 RGB/RGBA）
function colorOf(url) {
  const png = Buffer.from(url.slice(url.indexOf(",") + 1), "base64");
  const chunks = [];
  for (let at = 8; at < png.length;) {
    const length = png.readUInt32BE(at), type = png.toString("ascii", at + 4, at + 8);
    if (type === "IDAT") chunks.push(png.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  const [r, g, b] = inflateSync(Buffer.concat(chunks)).subarray(1, 4);
  const named = { red: [255, 0, 0], green: [0, 255, 0], blue: [0, 0, 255], white: [255, 255, 255], black: [0, 0, 0] };
  return Object.entries(named).sort(([, x], [, y]) =>
    Math.hypot(x[0] - r, x[1] - g, x[2] - b) - Math.hypot(y[0] - r, y[1] - g, y[2] - b))[0][0];
}

// 这一步该做什么：{ call: [工具, 参数] } 或 { say: 文字 } 或 { hold: 先吐的文字 }
async function decide(body, signal) {
  const messages = body.messages ?? [];
  const tools = (body.tools ?? []).map((t) => t.function.name);
  if (tools.length === 0) return { say: "Fake summary" };
  const last = messages.findLastIndex((m) => m.role === "user");
  const said = text(messages[last]?.content);
  const results = messages.slice(last + 1).filter((m) => m.role === "tool").map((m) => text(m.content));
  const tool = (name) => tools.find((t) => t === name || t.endsWith("_" + name)) ?? name;
  let m;
  if ((m = /call the echo tool with the text "([^"]*)".*?until you have made (\d+) calls/is.exec(said))) {
    if (results.length === 0) return { call: [tool("echo"), { text: m[1] }] };
    const latest = results.at(-1);
    if (results.length >= Number(m[2])) return { say: latest };
    await sleep(chainPause, signal);
    return { call: [tool("echo"), { text: latest }] };
  }
  if ((m = /use the shell tool to run exactly: (.+?)\s*\.?\s+then reply (\w+)/is.exec(said))) {
    return results.length ? { say: m[2] } : { call: [tool("shell"), { command: m[1], description: "Run the requested command" }] };
  }
  if ((m = /use the subagent tool with agent (\S+) and description (\S+), prompt: (.+?)\.\s.*reply (\w+)/is.exec(said))) {
    return results.length ? { say: m[4] } : { call: [tool("subagent"), { agent: m[1], description: m[2], prompt: m[3] }] };
  }
  if ((m = /use the question tool.*?header (\w+),? (?:and )?question (.+?\?) with options (\w+) and (\w+)/is.exec(said))) {
    if (!results.length) {
      const options = [m[3], m[4]].map((label) => ({ label, description: label }));
      return { call: [tool("question"), { questions: [{ header: m[1], question: m[2], options }] }] };
    }
    return { say: /="([^"]*)"/.exec(results.at(-1))?.[1] ?? results.at(-1) };
  }
  if ((m = /create a file named (\S+?)\.?\s/i.exec(said))) {
    return results.length ? { say: "I could not create it." } : { call: [tool("write"), { path: m[1], content: "x" }] };
  }
  if (/^write the numbers/i.test(said)) return { hold: "1\n" };
  if (/what is your codename/i.test(said)) {
    const system = messages.filter((m) => m.role === "system").map((m) => text(m.content)).join("\n");
    return { say: /codename is (\S+?)\./.exec(system)?.[1] ?? "UNKNOWN" };
  }
  if (/what color is this image/i.test(said)) {
    const image = (messages[last].content ?? []).find?.((p) => p.type === "image_url");
    return { say: image ? colorOf(image.image_url.url) : "no image" };
  }
  if (/what word did I ask you to remember/i.test(said)) {
    const earlier = messages.slice(0, last).filter((m) => m.role === "user").map((m) => text(m.content)).join("\n");
    return { say: /remember the word (\w+)/i.exec(earlier)?.[1] ?? "UNKNOWN" };
  }
  if ((m = /reply with (?:exactly |only )?(?:the (?:single )?word )?([A-Z][A-Z0-9]+)\b/i.exec(said)) && m[1] === m[1].toUpperCase()) {
    return { say: m[1] };
  }
  return { say: `ECHO ${said}` };
}

let calls = 0;
const server = createServer(async (request, response) => {
  if (request.method !== "POST") {
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify({ data: [] }));
  }
  let raw = "";
  for await (const chunk of request) raw += chunk;
  const body = JSON.parse(raw || "{}");
  const aborted = new AbortController();
  response.on("close", () => aborted.abort());
  const id = `fake-${++calls}`;
  const base = { id, object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000), model: body.model };
  const send = (delta, finish = null, usage) =>
    response.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta, finish_reason: finish }], ...(usage && { usage }) })}\n\n`);
  const prompt = Math.ceil(JSON.stringify(body.messages ?? []).length / 4);
  const usage = (output) => ({ prompt_tokens: prompt + 100, completion_tokens: output, total_tokens: prompt + 100 + output, prompt_tokens_details: { cached_tokens: 100 } });

  const step = await decide(body, aborted.signal);
  if (aborted.signal.aborted) return;
  response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  if (step.call) {
    const [name, args] = step.call;
    send({ role: "assistant", tool_calls: [{ index: 0, id: `call_${calls}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] });
    send({}, "tool_calls", usage(10));
  } else {
    send({ role: "assistant", content: "" });
    send({ content: step.say ?? step.hold });
    if (step.hold) await sleep(holdCeiling, aborted.signal);
    if (aborted.signal.aborted) return;
    send({}, "stop", usage(5));
  }
  response.end("data: [DONE]\n\n");
});

server.listen(0, "127.0.0.1", () => process.stdout.write(JSON.stringify({ port: server.address().port }) + "\n"));
process.stdin.resume();
process.stdin.on("end", () => process.exit(0));
