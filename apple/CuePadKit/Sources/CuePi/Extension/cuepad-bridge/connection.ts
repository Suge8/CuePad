// CuePad 这一端：会话的 socket，与 CuePad 发来的命令（协议见 CuePi README：每条回一个 `ack`，拒绝时带原因）。

import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { BUILTIN_COMMANDS, contextInfo, findModel, INTERNAL_COMMAND, isThinkingLevel, modelInfo, reason, type BuiltinCommand } from "./info.ts";
import { retry } from "./retry.ts";
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

/** 会话的 socket：`<目录>/<sessionId>.<pid>.sock`（目录 0700、socket 0600）；返回关闭它的函数（向每个客户端告别、删掉 socket 文件）。 */
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
	/** 删掉本会话的 socket 文件；也挂在进程退出上（进程被 SIGTERM 之外的方式结束时，Pi 不发 session_shutdown） */
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


/** 压缩命令受理后等多久：这段时间内失败算命令失败，之后只提示在 Pi 里 */
const COMPACT_FAILURE_WINDOW_MS = 1500;

/** CuePad 发来的一行命令：字段来自 JSON，类型没有保证，逐处校验后才用 */
type Command = Record<string, unknown>;
type Reject = (error: string) => void;

function isModelRef(value: unknown): value is { provider: string; id: string } {
	return typeof value === "object" && value !== null && "provider" in value && typeof value.provider === "string" && "id" in value && typeof value.id === "string";
}

function isImages(value: unknown): value is { mimeType: string; data: string }[] {
	return Array.isArray(value) && value.every((i) => typeof i?.mimeType === "string" && typeof i?.data === "string");
}

/** 会话文件里的条目数（不算文件头） */
function entriesOnDisk(file: string): number {
	return fs.readFileSync(file, "utf8").split("\n").filter((line) => line.trim().length > 0).length - 1;
}

function handleCommand(session: Session, socket: net.Socket, command: Command | null) {
	const ack: Ack = (fields) => session.write(socket, { t: "ack", id: command?.id ?? null, ...fields });
	const reject: Reject = (error) => ack({ ok: false, error });
	try {
		// 格式跨扩展版本不变、不回 ack（CuePi README「协议」）：CuePad 读不懂的旧扩展也要收得到
		if (command?.t === "upgrade") return session.reload.check();
		if (command?.t === "send") return handleSend(session, command, ack, reject);
		if (command?.t === "command") return void handleSlash(session, command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
		if (command?.t === "answer") return handleAnswer(session, command, ack, reject);
		if (command?.t === "reload") return handleReload(session, ack);
		if (command?.t === "end") return handleEnd(session, ack);
		if (command?.t === "abort") return handleAbort(session, ack);
		if (command?.t === "retry") return handleRetry(session, ack, reject);
		if (command?.t === "config") return void handleConfig(session, command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
		if (command?.t === "quota") return handleQuota(session, ack, reject);
		reject("bad_request");
	} catch (error) {
		reject(`failed: ${reason(error)}`);
	}
}

function handleSend(session: Session, command: Command, ack: Ack, reject: Reject) {
	const images = command.images ?? [];
	const text = command.text ?? "";
	if (typeof text !== "string" || !isImages(images)) return reject("bad_request");
	if (text.length === 0 && images.length === 0) return reject("empty");

	const content = images.length === 0
		? text
		: [{ type: "text" as const, text }, ...images.map((i) => ({ type: "image" as const, data: i.data, mimeType: i.mimeType }))];
	const id = typeof command.deliveryId === "string" ? command.deliveryId : undefined;
	session.startRound({ content, expand: false, text, id, ack });
}

/**
 * CuePad 在后台托管的同一会话刚做完一轮、让出退出：那一轮写进会话文件的内容，这个进程（用户打开时已载入）看不到。
 * 这个进程从载入起没写过，就把会话从文件重新载入到最新——之后说的话接在那一轮后面，不分支；写过了（会话已分出支线）
 * 就不动，提示一句。Pi 只在命令里给切换会话的能力（`switchSession`），所以经 `sendUserMessage` 触发本扩展的命令。
 */
function handleReload(session: Session, ack: Ack) {
	const { ctx } = session;
	const file = ctx.sessionManager.getSessionFile();
	const inMemory = ctx.sessionManager.getEntries().length;
	if (!file || entriesOnDisk(file) <= inMemory) return ack({ ok: true, reloaded: false });
	if (inMemory !== session.loadedEntries || !ctx.isIdle()) {
		ctx.ui.notify("CuePad 在后台跑的那一轮在你打开会话后才写完，会话分出了支线；用 /tree 查看", "warning");
		return ack({ ok: true, reloaded: false });
	}
	ack({ ok: true, reloaded: true });
	session.runInternal("reload-session");
}

/**
 * 斜杠命令：内置的（能在非 TUI 下执行的）由本扩展调 Pi 的接口做，其余（扩展命令、提示词模板、skill）经
 * `sendUserMessage(…, { expandPromptTemplates: true })` 交给 Pi 派发——扩展命令执行（会话正忙也立即执行，不开轮）、模板与 skill
 * 展开成新一轮的提示词，与 `send` 同一规则（`startRound`）；不带这个选项的 `sendUserMessage` 只把它当普通文字。清单里没有的名字拒绝，不当文字发出去。
 * `ack` 表示已受理：扩展命令的执行结果与报错只出现在 Pi 自己的界面（`ctx.ui`），这里看不到。
 */
async function handleSlash(session: Session, command: Command, ack: Ack, reject: Reject) {
	const text = command.text;
	if (typeof text !== "string" || !text.startsWith("/")) return reject("bad_request");
	const space = text.search(/\s/);
	const name = text.slice(1, space < 0 ? undefined : space);
	const args = space < 0 ? "" : text.slice(space + 1).trim();
	const builtin = BUILTIN_COMMANDS.find((c) => c.name === name);
	if (builtin) {
		const error = await runBuiltin(session, builtin, args);
		return error ? reject(error) : ack({ ok: true });
	}
	const found = name === INTERNAL_COMMAND ? undefined : session.pi.getCommands().find((c) => c.name === name);
	if (!found) return reject("unknown_command");
	if (found.source === "extension") session.pi.sendUserMessage(text, { expandPromptTemplates: true });
	else session.startRound({ content: text, expand: true, text });
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
		case "new":
		case "reload":
			session.runInternal(builtin.name);
			return;
	}
	session.updateInfo({ ...await modelInfo(pi, ctx), ...contextInfo(ctx) });
}

/** 压缩不等完成就返回；开头一小段时间内的失败（没有可压缩的内容、没有模型）当作拒绝报给手机，之后的失败只能提示在 Pi 里。 */
function compact(session: Session, instructions: string): Promise<string | undefined> {
	return new Promise((resolve) => {
		const early = setTimeout(() => resolve(undefined), COMPACT_FAILURE_WINDOW_MS);
		session.ctx.compact({
			customInstructions: instructions || undefined,
			onComplete: () => { clearTimeout(early); resolve(undefined); },
			onError: (error: Error) => {
				clearTimeout(early);
				session.ctx.ui.notify(`压缩失败：${error.message}`, "error");
				resolve(`failed: ${error.message}`);
			},
		});
	});
}

/**
 * 结束会话：与用户在 Pi 里退出同一条路（`ctx.shutdown`——TUI 恢复终端并提示怎么恢复会话，退出时发 `bye quit`）。
 * 正在跑的一轮先中止、等你回答的弹窗先取消，否则 Pi 要等它们结束才会退出。RPC 模式只在读到下一条命令或这一轮结束时检查退出请求，
 * 所以后台托管的进程不走这里，由 CuePad 给它发 SIGTERM（`PiBridge.end`）。
 */
function handleEnd(session: Session, ack: Ack) {
	ack({ ok: true });
	session.asking?.dismiss?.();
	if (!session.ctx.isIdle()) session.ctx.abort();
	session.ctx.shutdown();
}

/** 停止这一轮（`stopRound`）；子代理落定后照常把结果投回来开始新的一轮。 */
function handleAbort(session: Session, ack: Ack) {
	session.stopRound();
	ack({ ok: true });
}

/** 把出错的那一轮原样重跑一遍（`retry.ts`）；确认等重跑的那一轮开始（隐藏消息落成会话里的一条消息）。 */
function handleRetry(session: Session, ack: Ack, reject: Reject) {
	const error = retry(session, ack);
	if (error) reject(error);
}

/** 会话设置：会话名（Pi 设置会话名的接口，同 `/name`）、模型、思考强度——先换模型（需要该提供方已配好密钥）再设强度，强度由 Pi 按新模型支持的范围夹取。 */
async function handleConfig(session: Session, command: Command, ack: Ack, reject: Reject) {
	const { pi, ctx } = session;
	const { model, thinking } = command;
	const name = typeof command.name === "string" ? command.name.trim() : command.name;
	if (model !== undefined && !isModelRef(model)) return reject("bad_request");
	if (thinking !== undefined && !isThinkingLevel(thinking)) return reject("bad_request");
	if (name !== undefined && (typeof name !== "string" || name.length === 0)) return reject("bad_request");
	if (model === undefined && thinking === undefined && name === undefined) return reject("bad_request");
	if (name) pi.setSessionName(name);
	if (model) {
		const target = ctx.modelRegistry.find(model.provider, model.id);
		if (!target) return reject("unknown_model");
		if (!(await pi.setModel(target))) return reject("no_auth");
	}
	if (thinking) pi.setThinkingLevel(thinking);
	session.updateInfo(await modelInfo(pi, ctx));
	ack({ ok: true });
}

/** 回答当前弹窗：标识必须是正在等的那个（答过或换了弹窗就拒绝），答案的类型与选项要对得上。 */
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

/** 每个订阅授权都报能力或结果；没有授权与查询失败带上原因，不把空查询当成功。 */
function handleQuota(session: Session, ack: Ack, reject: Reject) {
	void session.quota.fetchAll().then(async (failures) => {
		session.updateInfo(await modelInfo(session.pi, session.ctx));
		failures.length === 0 ? ack({ ok: true }) : reject(`failed: ${failures.join("; ")}`);
	});
}
