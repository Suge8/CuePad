// CuePad 随包的 dsh 插件（`--patch` 叠在 `--profile acp` 上，不装进用户的 profile）。
//
// 标准输入输出归 ACP：插件接管 dsh-acp 的传输（它的 `config.stream`），逐行分流——`_cuepad/` 开头的是 CuePad 的扩展方法，
// 插件自己答；其余原样交给 dsh-acp。扩展通知与 ACP 的消息经同一个写端按产生的先后写出，正在说的话与它的定稿不会错序。
// ACP 标准里没有、CuePad 要的：
//   通知 `_cuepad/delta`    {sessionId, text}：模型正在说的话的增量（ACP 只发说完的整段）；`_cuepad/step` {sessionId}：新的一步开始（重试也算），之前的增量作废
//   通知 `_cuepad/status`   {sessionId, running}：这个会话的 Agent 开始、歇下（插话开出的一轮没有 ACP 的 prompt 回应）
//   通知 `_cuepad/question` {sessionId, id, questions}：`ask_user_question` 要你回答；`questions` 为 null 是收回（这一轮停下了）
//   方法 `_cuepad/steer`    {sessionId, text, images?[{mimeType, data}], deliveryId?}：插进在跑的这一轮，下一步就读到；歇着时拒绝（error.data.idle），该走 session/prompt
//   方法 `_cuepad/answer`   {id, answers[{id, selected[], custom?}]}
//   方法 `_cuepad/commands` {sessionId} → {commands[{name, description, hint}]}；`_cuepad/command` {sessionId, line}
//   方法 `_cuepad/rename`   {sessionId, name}
// CuePad 送进去的话带投送请求 id（`session/prompt` 的 `_meta.cuepadDelivery`、插话的 `deliveryId`）：这句话进收件箱时插件往会话记录里
// 先记一条 `plugin:cuepad/delivery` {message, delivery}，随后的 `user/message` 按 message id 认（`DshHistory`）。
// config.prompt：给了就是 Cue 的大脑，整份替换系统提示（文件路径，原样不插值）。
// 环境 CUEPAD_MODEL（`提供方/模型`）：新会话用它；没给用 acp profile 的缺省模型（`agent-default-model`，dsh-acp 自己写死的那个不用）。
// dsh-acp 只在握手时按这个模型判定收不收图（`promptCapabilities.image`），之后换到能看图的模型也不改。
// 环境 CUEPAD_PROBE=1：不答 ACP，等模型清单就绪后写一行 {"cuepadProbe": {model, models}} 并退出（`DshRuntime.facts.probe`）。
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { StringDecoder } from "node:string_decoder";

export const name = "cuepad";
export const inject = ["agents", "commands", "llm", "systemPrompt", "agentDefaultModel", "acpAppStartup"];

const prefix = "_cuepad/";
const efforts = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

export async function apply(ctx, config = {}) {
  if (config.prompt) {
    const text = readFileSync(config.prompt, "utf8");
    ctx.effect(() => ctx.systemPrompt.section({ name: "cuepad:cue", order: 0, text, interpolate: false, complete: true }));
  }
  const write = (message) => process.stdout.write(JSON.stringify(message) + "\n");
  const notify = (method, params) => write({ jsonrpc: "2.0", method: prefix + method, params });
  let toAcp;
  const readable = new ReadableStream({ start: (controller) => { toAcp = controller; } });
  const writable = new WritableStream({ write });
  if (process.env.CUEPAD_PROBE === "1") {
    // dsh-acp 等着这个服务：不给它就算启动失败。探测时它收不到任何消息
    ctx.provide("cuepadAcp", { stream: { readable, writable }, ...route(ctx) });
    return void probe(ctx);
  }
  const deliveries = await delivered(ctx);
  const methods = handlers(ctx, notify, deliveries);
  ctx.provide("cuepadAcp", { stream: { readable, writable }, ...route(ctx) });
  const decoder = new StringDecoder("utf8");
  let buffer = "";
  process.stdin.on("data", (chunk) => {
    buffer += decoder.write(chunk);
    let end;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (line.trim() === "") continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (typeof message.method === "string" && message.method.startsWith(prefix)) call(methods, message, write);
      else {
        if (message.method === "session/prompt") deliveries.expect(message.params?.sessionId, message.params?._meta?.cuepadDelivery);
        toAcp.enqueue(message);
      }
    }
  });
  process.stdin.on("end", () => toAcp.close());

  ctx.on("agent/status", ({ agent, status }) => notify("status", { sessionId: agent.session.id, running: status === "running" }));
  ctx.on("agent/assistant-stream", ({ agent, frame }) => {
    if (frame.type === "start") return notify("step", { sessionId: agent.session.id });
    if (frame.type === "chunk" && frame.chunk.type === "text-delta") notify("delta", { sessionId: agent.session.id, text: frame.chunk.text });
  });
}

function route(ctx) {
  const chosen = process.env.CUEPAD_MODEL;
  if (!chosen) return ctx.agentDefaultModel.currentSelection();
  const slash = chosen.indexOf("/");
  return { provider: chosen.slice(0, slash), model: chosen.slice(slash + 1) };
}

/** 等着进收件箱的投送请求 id（按会话，一次只有一轮 prompt）；进了就记进会话记录。 */
async function delivered(ctx) {
  const { appendPluginRecord } = await ctx.loader.internal.import("@deepseek-ai/dsh-session", ctx.baseUrl, {});
  const expected = new Map();
  const record = (agent, message, delivery) => appendPluginRecord(agent.session, "plugin:cuepad/delivery", { message: message.id, delivery });
  ctx.on("agent/inbox/inserted", ({ agent, message }) => {
    const delivery = expected.get(agent.session.id);
    if (delivery === undefined || message.source?.kind !== "user") return;
    expected.delete(agent.session.id);
    record(agent, message, delivery);
  });
  return {
    expect(sessionId, delivery) { if (sessionId && delivery) expected.set(sessionId, delivery); },
    record,
  };
}

function handlers(ctx, notify, deliveries) {
  const questions = new Map();
  const agent = (sessionId) => {
    const found = ctx.agents.get(sessionId);
    if (!found) throw failure(`unknown session ${sessionId}`);
    return found;
  };
  ctx.on("user-questions/request", (request, next) => {
    if (request.agent === undefined) return next();
    const id = randomUUID(), sessionId = request.agent.session.id;
    return new Promise((resolve, reject) => {
      questions.set(id, resolve);
      request.signal?.addEventListener("abort", () => {
        questions.delete(id);
        notify("question", { sessionId, id, questions: null });
        reject(request.signal.reason);
      }, { once: true });
      notify("question", { sessionId, id, questions: request.questions });
    });
  });
  return {
    async steer({ sessionId, text, images = [], deliveryId }) {
      const target = agent(sessionId);
      if (target.status !== "running") throw failure("the session is idle: send it as a prompt", { idle: true });
      const refs = images.length === 0 ? [] : await ctx.get("attachments").saveImages(
        images.map((image) => ({ mediaType: image.mimeType, data: Buffer.from(image.data, "base64") })));
      const content = [...(text ? [{ type: "text", text }] : []), ...refs.map((attachment) => ({ type: "image", attachment }))];
      const message = Object.freeze({ id: randomUUID(), role: "user", content, source: { kind: "user" } });
      if (deliveryId) deliveries.record(target, message, deliveryId);
      target.steer(message);
      return {};
    },
    answer({ id, answers }) {
      const resolve = questions.get(id);
      if (!resolve) throw failure(`no open question ${id}`);
      questions.delete(id);
      resolve({ answers });
      return {};
    },
    commands({ sessionId }) {
      return { commands: ctx.commands.list(agent(sessionId)).map((c) => ({ name: c.name, description: c.description, hint: c.input?.hint })) };
    },
    async command({ sessionId, line }) {
      const done = await ctx.commands.execute(agent(sessionId), line, [], new AbortController().signal);
      if (done === undefined) throw failure(`unknown command: ${line}`);
      return {};
    },
    async rename({ sessionId, name }) {
      await ctx.get("sessionTitle").rename(agent(sessionId).session, name);
      return {};
    },
  };
}

function call(methods, message, write) {
  const method = methods[message.method.slice(prefix.length)];
  const reply = (body) => { if ("id" in message) write({ jsonrpc: "2.0", id: message.id, ...body }); };
  if (!method) return reply({ error: { code: -32601, message: `"Method not found": ${message.method}` } });
  Promise.resolve().then(() => method(message.params ?? {})).then(
    (result) => reply({ result }),
    (error) => reply({ error: { code: error?.code ?? -32603, message: String(error?.message ?? error), data: error?.data } }));
}

function failure(message, data) {
  return Object.assign(new Error(message), { code: -32000, data });
}

/** 和会话的模型菜单同一份（`llm` 的提供方与各自的模型清单）；一个模型都没有是没登录。缺省模型是新会话用的那个（用户在 dsh 里设的）。 */
async function probe(ctx) {
  // 先取下服务：标准输入一关 dsh 就开始收场，之后的 ctx 拿不到它们
  const { llm, agentDefaultModel } = ctx;
  const models = [];
  for (const provider of llm.listProviders()) {
    let listed = [];
    try { listed = await llm.listModels(provider.id); } catch {}
    for (const model of listed) {
      const info = await llm.resolveModelInfo(provider.id, model.id, new AbortController().signal).catch(() => undefined);
      models.push({
        provider: provider.id, id: model.id, name: model.name,
        thinking: (info?.reasoning?.efforts ?? []).map((effort) => String(effort.id)).filter((id) => efforts.includes(id)),
        ...(model.inputModalities ? { images: model.inputModalities.includes("image") } : {}),
      });
    }
  }
  const chosen = agentDefaultModel.currentSelection();
  const model = models.find((m) => m.provider === chosen.provider && m.id === chosen.model) ?? null;
  process.stdout.write(JSON.stringify({ cuepadProbe: { model, models } }) + "\n", () => process.exit(0));
}
