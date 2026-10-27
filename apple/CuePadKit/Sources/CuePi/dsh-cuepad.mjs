// CuePad 随包的 dsh 插件（`--patch` 叠在 `--profile acp` 上，不装进用户的 profile），把 dsh-acp 补成 CuePad 的 ACP 驱动用的标准样子。
//
// 标准输入输出归 ACP：插件接管 dsh-acp 的传输（它的 `config.stream`），进出的每一行都经过这里，出去的按产生的先后写出。
// dsh-acp 没有、这里补上的标准部分：
//   - 正在说的话：dsh-acp 只在一段话说完时发整段 `agent_message_chunk`；这里把模型的逐字增量发成同样的 `agent_message_chunk`，
//     随后那条整段的（与增量拼起来相同）不再发
//   - 斜杠命令：会话开好（`session/new`、`session/load` 的回应）后发 `available_commands_update`；`/` 开头、命令名认得的 `session/prompt`
//     由这里执行（`ctx.commands`）并回它，不交给 dsh-acp
//   - `session/load`：dsh-acp 只有 `session/resume`（不重放历史），改名转给它
//   - 模型选项的值：dsh-acp 的是 `["提供方","模型"]` 的 JSON 原文，进出都换成 CuePad 的写法 `提供方/模型`
// 标准没有的，CuePad 的扩展方法（`ACPDialect`）：
//   `_cuepad/steer`  {sessionId, text, images?[{mimeType, data}]}：插进在跑的这一轮，下一步就读到；歇着时回错误码 -32001，该走 session/prompt
//   `_cuepad/rename` {sessionId, name}
// CuePad 送进去的话带投送请求 id（`session/prompt` 的 `_meta.cuepadDelivery`）：这句话进收件箱时往会话记录里先记一条
// `plugin:cuepad/delivery` {message, delivery}，随后的 `user/message` 按 message id 认（`DshHistory`）。
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
  const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
  const update = (sessionId, update) => send({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update } });
  let toAcp;
  const readable = new ReadableStream({ start: (controller) => { toAcp = controller; } });
  if (process.env.CUEPAD_PROBE === "1") {
    // dsh-acp 等着这个服务：不给它就算启动失败。探测时它收不到任何消息
    ctx.provide("cuepadAcp", { stream: { readable, writable: new WritableStream({ write: send }) }, ...route(ctx) });
    return void probe(ctx);
  }

  const { appendPluginRecord } = await ctx.loader.internal.import("@deepseek-ai/dsh-session", ctx.baseUrl, {});
  /** 每个会话：已作为增量发出、还没等到整段的话；等着进收件箱的投送请求 id */
  const streamed = new Map(), deliveries = new Map();
  /** 发出去的请求里认会话开好的回应：请求 id → 会话 id（`session/load` 的请求里就有） */
  const opening = new Map();

  const fromAcp = (message) => {
    if (message.result?.configOptions) message = { ...message, result: { ...message.result, configOptions: rewriteModels(message.result.configOptions) } };
    const u = message.params?.update;
    if (u?.configOptions) message = { ...message, params: { ...message.params, update: { ...u, configOptions: rewriteModels(u.configOptions) } } };
    if (message.method === "session/update" && u?.sessionUpdate === "agent_message_chunk" && typeof u.content?.text === "string") {
      const pending = streamed.get(message.params.sessionId) ?? "";
      if (pending.startsWith(u.content.text)) return void streamed.set(message.params.sessionId, pending.slice(u.content.text.length));
      streamed.delete(message.params.sessionId);
    }
    send(message);
    if (!("method" in message) && opening.has(message.id)) {
      const sessionId = message.result?.sessionId ?? opening.get(message.id);
      opening.delete(message.id);
      const agent = sessionId && ctx.agents.get(sessionId);
      if (agent) update(sessionId, { sessionUpdate: "available_commands_update", availableCommands: commands(ctx, agent) });
    }
  };
  ctx.provide("cuepadAcp", { stream: { readable, writable: new WritableStream({ write: fromAcp }) }, ...route(ctx) });

  ctx.on("agent/assistant-stream", ({ agent, frame }) => {
    if (frame.type !== "chunk" || frame.chunk.type !== "text-delta") return;
    const sessionId = agent.session.id;
    streamed.set(sessionId, (streamed.get(sessionId) ?? "") + frame.chunk.text);
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: frame.chunk.text } });
  });
  ctx.on("agent/inbox/inserted", ({ agent, message }) => {
    const delivery = deliveries.get(agent.session.id);
    if (delivery === undefined || message.source?.kind !== "user") return;
    deliveries.delete(agent.session.id);
    appendPluginRecord(agent.session, "plugin:cuepad/delivery", { message: message.id, delivery });
  });

  const methods = extensions(ctx);
  const toAgent = (message) => {
    if (typeof message.method === "string" && message.method.startsWith(prefix)) return answer(message, () => methods[message.method.slice(prefix.length)], send);
    const params = message.params ?? {};
    switch (message.method) {
      case "session/new":
        opening.set(message.id, undefined);
        break;
      case "session/set_config_option":
        if (params.configId === "model") message = { ...message, params: { ...params, value: modelValue(params.value) } };
        break;
      case "session/load":
        opening.set(message.id, params.sessionId);
        message = { ...message, method: "session/resume" };
        break;
      case "session/prompt": {
        const agent = ctx.agents.get(params.sessionId);
        const line = params.prompt?.length === 1 && params.prompt[0].type === "text" ? params.prompt[0].text : "";
        const name = line.startsWith("/") ? line.slice(1).split(/\s/, 1)[0] : undefined;
        if (agent && name && commands(ctx, agent).some((c) => c.name === name)) {
          return answer(message, () => async () => {
            await ctx.commands.execute(agent, line, [], new AbortController().signal);
            return { stopReason: "end_turn" };
          }, send);
        }
        if (params._meta?.cuepadDelivery) deliveries.set(params.sessionId, params._meta.cuepadDelivery);
        break;
      }
    }
    toAcp.enqueue(message);
  };
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
      toAgent(message);
    }
  });
  process.stdin.on("end", () => toAcp.close());
}

function route(ctx) {
  const chosen = process.env.CUEPAD_MODEL;
  if (!chosen) return ctx.agentDefaultModel.currentSelection();
  const slash = chosen.indexOf("/");
  return { provider: chosen.slice(0, slash), model: chosen.slice(slash + 1) };
}

function commands(ctx, agent) {
  return ctx.commands.list(agent).map((c) => ({ name: c.name, description: c.description ?? "", ...(c.input?.hint ? { input: { hint: c.input.hint } } : {}) }));
}

function extensions(ctx) {
  const agent = (sessionId) => {
    const found = ctx.agents.get(sessionId);
    if (!found) throw failure(`unknown session ${sessionId}`);
    return found;
  };
  return {
    async steer({ sessionId, text, images = [] }) {
      const target = agent(sessionId);
      if (target.status !== "running") throw failure("the session is idle: send it as a prompt", idle);
      const refs = images.length === 0 ? [] : await ctx.get("attachments").saveImages(
        images.map((image) => ({ mediaType: image.mimeType, data: Buffer.from(image.data, "base64") })));
      const content = [...(text ? [{ type: "text", text }] : []), ...refs.map((attachment) => ({ type: "image", attachment }))];
      target.steer(Object.freeze({ id: randomUUID(), role: "user", content, source: { kind: "user" } }));
      return {};
    },
    async rename({ sessionId, name }) {
      await ctx.get("sessionTitle").rename(agent(sessionId).session, name);
      return {};
    },
  };
}

/** 插件自己答的请求（通知不回）：`handler()` 给出处理函数，没有就是"没有这个方法"。 */
function answer(message, handler, send) {
  const reply = (body) => { if ("id" in message) send({ jsonrpc: "2.0", id: message.id, ...body }); };
  const method = handler();
  if (!method) return reply({ error: { code: -32601, message: `"Method not found": ${message.method}` } });
  Promise.resolve().then(() => method(message.params ?? {})).then(
    (result) => reply({ result }),
    (error) => reply({ error: { code: error?.code ?? -32603, message: String(error?.message ?? error) } }));
}

/** `_cuepad/steer` 遇上歇着的会话（`DshDialect.idle`） */
const idle = -32001;

function failure(message, code = -32000) {
  return Object.assign(new Error(message), { code });
}

/** dsh-acp 的模型选项值是 `["提供方","模型"]` 的 JSON 原文；对 CuePad 写成 `提供方/模型`（`AgentKind.modelRef`）。 */
const modelRef = (value) => {
  try { const [provider, model] = JSON.parse(value); return `${provider}/${model}`; } catch { return value; }
};
const modelValue = (ref) => {
  const slash = ref.indexOf("/");
  return slash < 0 ? ref : JSON.stringify([ref.slice(0, slash), ref.slice(slash + 1)]);
};

/** 出去的配置项里模型那一项的值改成 `提供方/模型`。 */
function rewriteModels(options) {
  const values = (list) => list?.map((o) => (o.options ? { ...o, options: values(o.options) } : { ...o, value: modelRef(o.value) }));
  return options.map((o) => (o.category === "model" ? { ...o, currentValue: modelRef(o.currentValue), options: values(o.options) } : o));
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
