import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import type { SlashCommandInfo } from "@earendil-works/pi-coding-agent";
import { BUILTIN_COMMANDS, contextInfo, findModel, INTERNAL_COMMAND, isThinkingLevel, modelInfo, reason, type BuiltinCommand } from "./info.ts";
import { supportsFast } from "./fast.ts";
import { retry } from "./retry.ts";
import { handleTitle } from "./title.ts";
import type { Ack, Session } from "./session.ts";

/** sun_path 上限 104 字节（含结尾 NUL） */
const SUN_PATH_LIMIT = 104;
/** 一行命令（含 base64 图片）的上限，超过就断开该客户端 */
const MAX_LINE_BYTES = 64 * 1024 * 1024;

/** 目录必须是"当前用户的 0700 目录"，否则拒绝（/tmp 下的目录可能被他人预先创建）。 */
function ensureSecureDirectory(dir: string): void {
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	const st = fs.lstatSync(dir);
	if (!st.isDirectory() || st.uid !== process.getuid!() || (st.mode & 0o777) !== 0o700) {
		throw new Error(`${dir} is not a directory owned by you with mode 0700`);
	}
}

async function onConnection(session: Session, socket: net.Socket) {
	socket.on("error", () => socket.destroy());
	const greeting = await session.hello();
	if (socket.destroyed) return;
	session.clients.add(socket);
	socket.on("close", () => session.clients.delete(socket));
	session.write(socket, greeting);
	session.quota.capabilities(greeting.models, greeting.model?.provider);

	let buffer = "";
	socket.setEncoding("utf8");
	socket.on("data", (chunk: string) => {
		buffer += chunk;
		if (buffer.length > MAX_LINE_BYTES) return socket.destroy();
		let newline: number;
		while ((newline = buffer.indexOf("\n")) >= 0) {
			const line = buffer.slice(0, newline);
			buffer = buffer.slice(newline + 1);
			if (!line) continue;
			let command: Command | null;
			try {
				command = JSON.parse(line);
			} catch {
				session.write(socket, { t: "ack", id: null, ok: false, error: "bad_request" });
				continue;
			}
			handleCommand(session, socket, command);
		}
	});
}

export function listen(session: Session, directory: string): (reason: string) => void {
	ensureSecureDirectory(directory);
	const name = path.join(directory, `${session.ctx.sessionManager.getSessionId()}.${process.pid}`);
	const file = `${name}.sock`;
	const pending = `${name}.tmp`; // 比 file 短，file 不超限它就不超
	if (Buffer.byteLength(file) >= SUN_PATH_LIMIT) throw new Error(`socket path too long: ${file}`);
	fs.rmSync(file, { force: true });
	fs.rmSync(pending, { force: true });
	let server: net.Server | undefined = net.createServer((socket) => void onConnection(session, socket));
	const own = server;
	own.on("error", () => {});
	// 在临时名上 listen、收紧成 0600，再改名进来：CuePad 盯着目录（kqueue），名字一出现就连，这时它已在 listen、权限已收紧。
	// listen 好之前已经收掉的（stop）不再改名：同一路径上可能已是接替它的那个
	own.listen(pending, () => {
		if (server !== own) return;
		fs.chmodSync(pending, 0o600);
		fs.renameSync(pending, file);
	});
	/** 也挂在进程退出上：进程被 SIGTERM 之外的方式结束时，Pi 不发 session_shutdown */
	const removeSocket = () => {
		fs.rmSync(file, { force: true });
		fs.rmSync(pending, { force: true });
	};
	process.on("exit", removeSocket);

	return (reason) => {
		for (const client of session.clients) {
			session.write(client, { t: "bye", reason });
			client.end();
		}
		session.clients.clear();
		server?.close();
		server = undefined;
		process.off("exit", removeSocket);
		removeSocket();
	};
}


/** CuePad 发来的一行命令：字段来自 JSON，类型没有保证，逐处校验后才用 */
type Command = Record<string, unknown>;
type Reject = (error: string) => void;

function isModelRef(value: unknown): value is { provider: string; id: string } {
	return typeof value === "object" && value !== null && "provider" in value && typeof value.provider === "string" && "id" in value && typeof value.id === "string";
}

function isImages(value: unknown): value is { mimeType: string; data: string }[] {
	return Array.isArray(value) && value.every((i) => typeof i?.mimeType === "string" && typeof i?.data === "string");
}

function handleCommand(session: Session, socket: net.Socket, command: Command | null) {
	const ack: Ack = (fields) => session.write(socket, { t: "ack", id: command?.id ?? null, ...fields });
	const reject: Reject = (error) => ack({ ok: false, error });
	try {
		// 格式跨扩展版本不变、不回 ack（CueBridge README「协议」）：CuePad 读不懂的旧扩展也要收得到
		if (command?.t === "upgrade") return session.reload.check();
		if (command?.t === "send") return void handleSend(session, command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
		if (command?.t === "command") return void handleSlash(session, command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
		if (command?.t === "answer") return handleAnswer(session, command, ack, reject);
		if (command?.t === "end") return handleEnd(session, ack);
		if (command?.t === "abort") return handleAbort(session, ack);
		if (command?.t === "abortTurn") {
			if (typeof command.deliveryId !== "string" || !command.deliveryId || typeof command.turnStartedAt !== "number"
				|| !Number.isSafeInteger(command.turnStartedAt)) return reject("bad_request");
			return session.stopDelivery(command.deliveryId, command.turnStartedAt) ? ack({ ok: true }) : reject("stale_turn");
		}
		if (command?.t === "retry") return void handleRetry(session, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
		if (command?.t === "config") return void handleConfig(session, command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
		if (command?.t === "quota") return handleQuota(session, ack, reject);
		if (command?.t === "title") return void handleTitle(session, command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
		reject("bad_request");
	} catch (error) {
		reject(`failed: ${reason(error)}`);
	}
}

async function handleSend(session: Session, command: Command, ack: Ack, reject: Reject) {
	const images = command.images ?? [];
	const text = command.text ?? "";
	if (typeof text !== "string" || !isImages(images)) return reject("bad_request");
	if (text.length === 0 && images.length === 0) return reject("empty");

	const content = images.length === 0
		? text
		: [{ type: "text" as const, text }, ...images.map((i) => ({ type: "image" as const, data: i.data, mimeType: i.mimeType }))];
	const id = typeof command.deliveryId === "string" ? command.deliveryId : undefined;
	const cueTurn = command.cueTurn;
	if (cueTurn !== undefined && (typeof cueTurn !== "object" || cueTurn === null || Array.isArray(cueTurn)
		|| ("deliveryId" in cueTurn && cueTurn.deliveryId !== null && typeof cueTurn.deliveryId !== "string"))) return reject("bad_request");
	const found = slashCommand(session, text);
	const expand = found !== undefined && "source" in found && (found.source === "prompt" || found.source === "skill");
	await session.startRound({ content, expand, text, id, ack, cueTurn: cueTurn as { deliveryId?: string | null } | undefined });
}

/** 一行以哪条斜杠命令开头，与 Pi 派发同一先后：本扩展执行的内置命令先于 Pi 清单里的扩展命令、提示词模板与 skill，同名时扩展命令在前（Pi 也先执行它）。 */
function slashCommand(session: Session, text: string): BuiltinCommand | SlashCommandInfo | undefined {
	if (!text.startsWith("/")) return undefined;
	const space = text.search(/\s/);
	const name = text.slice(1, space < 0 ? undefined : space);
	if (name === INTERNAL_COMMAND) return undefined;
	return BUILTIN_COMMANDS.find((c) => c.name === name) ?? session.pi.getCommands().find((c) => c.name === name);
}

/**
 * 斜杠命令。不带 `expandPromptTemplates` 的 `sendUserMessage` 只把它当普通文字，所以清单里没有的名字拒绝，不当文字发出去。
 * 扩展命令交出即确认：Pi 在任何检查之前同步调起它的处理函数（`AgentSession.prompt`，1.4.0 起；只有正在发 agent_settled 时推到发完再调），
 * 会话正忙也立即执行、不开轮，没有拒收的路。处理函数的完成与出错没有公开回执（出错 Pi 报在它自己的界面），ACK 只证明 Pi 执行了它。
 * 模板与 skill 是你说的话，CuePad 经 `send` 交出（落成的消息带投送请求 id）；经这里来的照样展开开轮。
 */
async function handleSlash(session: Session, command: Command, ack: Ack, reject: Reject) {
	const text = command.text;
	if (typeof text !== "string" || !text.startsWith("/")) return reject("bad_request");
	const found = slashCommand(session, text);
	if (!found) return reject("unknown_command");
	if (!("source" in found)) {
		const space = text.search(/\s/);
		const error = await runBuiltin(session, found, space < 0 ? "" : text.slice(space + 1).trim());
		return error ? reject(error) : ack({ ok: true });
	}
	if (found.source !== "extension") return session.startRound({ content: text, expand: true, text, ack });
	session.pi.sendUserMessage(text, { expandPromptTemplates: true });
	ack({ ok: true });
}

/** 执行一条内置命令；返回拒绝原因，成功返回 undefined。 */
async function runBuiltin(session: Session, builtin: BuiltinCommand, args: string): Promise<string | undefined> {
	const { pi, ctx } = session;
	if ("required" in builtin && !args) return "missing_argument";
	switch (builtin.name) {
		case "compact": return compact(session, args);
		case "name": pi.setSessionName(args); return;
		case "thinking":
			if (!isThinkingLevel(args)) return "bad_request";
			pi.setThinkingLevel(args);
			break;
		case "model": {
			const target = findModel(ctx, args);
			if (!target) return "unknown_model";
			if (!(await pi.setModel(target))) return "no_auth";
			break;
		}
		case "clone":
			if (!ctx.sessionManager.getLeafId()) return "failed: nothing to clone";
			session.runInternal("clone");
			return;
		case "reload":
			session.reload.request();
			return;
		case "new":
			session.runInternal(builtin.name);
			return;
	}
	session.updateInfo({ ...await modelInfo(pi, ctx), ...contextInfo(ctx) });
}

/** 只回一次真实压缩结果；超过桥的等待期限仍由公开压缩事件上报状态，不把未完成当成功。 */
function compact(session: Session, instructions: string): Promise<string | undefined> {
	return new Promise((resolve) => {
		session.ctx.compact({
			customInstructions: instructions || undefined,
			onComplete: () => resolve(undefined),
			onError: (error: Error) => {
				session.ctx.ui.notify(`压缩失败：${error.message}`, "error");
				resolve(`failed: ${error.message}`);
			},
		});
	});
}

/** 先回受理，再经命令上下文等真实空闲后按 mode 退出；ACK 不是结束完成。 */
function handleEnd(session: Session, ack: Ack) {
	ack({ ok: true });
	for (const said of session.pending.splice(0)) said.ack?.({ ok: false, error: "failed: session is ending" });
	session.stopRound();
	session.runInternal("end");
}

/** 子代理落定后照常把结果投回来开始新的一轮。排着、还没交出的话一并作废（停下之后不该又开一轮），它们的确认回未执行。 */
function handleAbort(session: Session, ack: Ack) {
	session.abortQueued();
	session.stopRound();
	ack({ ok: true });
}

async function handleRetry(session: Session, ack: Ack, reject: Reject) {
	const error = await retry(session, ack);
	if (error) reject(error);
}

/** 先换模型（需要该提供方已配好密钥）再设强度，强度由 Pi 按新模型支持的范围夹取。 */
async function handleConfig(session: Session, command: Command, ack: Ack, reject: Reject) {
	const { pi, ctx } = session;
	const { model, thinking, fast } = command;
	const name = typeof command.name === "string" ? command.name.trim() : command.name;
	if (model !== undefined && !isModelRef(model)) return reject("bad_request");
	if (thinking !== undefined && !isThinkingLevel(thinking)) return reject("bad_request");
	if (name !== undefined && (typeof name !== "string" || name.length === 0)) return reject("bad_request");
	if (fast !== undefined && typeof fast !== "boolean") return reject("bad_request");
	if (model === undefined && thinking === undefined && fast === undefined && name === undefined) return reject("bad_request");
	const target = model ? ctx.modelRegistry.find(model.provider, model.id) : ctx.model;
	if (model && !target) return reject("unknown_model");
	if (fast === true && !supportsFast(target)) return reject("bad_request");
	if (name) pi.setSessionName(name);
	if (model && target && !(await pi.setModel(target))) return reject("no_auth");
	if (thinking) pi.setThinkingLevel(thinking);
	const selectedFast = typeof fast === "boolean" ? fast : model && !supportsFast(target) && session.fast ? false : undefined;
	if (typeof selectedFast === "boolean") session.setFast(selectedFast);
	session.updateInfo(await modelInfo(pi, ctx));
	ack({ ok: true });
}

function handleAnswer(session: Session, command: Command, ack: Ack, reject: Reject) {
	const pending = session.asking;
	if (!pending?.settle) return reject("no_prompt");
	if (pending.id !== command.promptId) return reject("stale_prompt");
	const value = command.value;
	const valid = pending.kind === "confirm" ? typeof value === "boolean"
		: pending.kind === "select" ? typeof value === "string" && pending.options.includes(value)
		: typeof value === "string";
	if (!valid) return reject("bad_answer");
	pending.settle(value);
	session.asking = null;
	ack({ ok: true });
}

/** 没有授权与查询失败带上原因，不把空查询当成功。 */
function handleQuota(session: Session, ack: Ack, reject: Reject) {
	void session.quota.fetchAll().then(async (failures) => {
		session.updateInfo(await modelInfo(session.pi, session.ctx));
		failures.length === 0 ? ack({ ok: true }) : reject(`failed: ${failures.join("; ")}`);
	});
}
