// CuePad Pi bridge extension
// 由 CuePad 安装到 Pi 扩展目录，升级时整文件覆盖，请勿手改。协议说明见 apple/CuePadKit/Sources/CuePi/README.md。
//
// 每个 Pi 会话在 socket 目录开一个 `<sessionId>.<pid>.sock`（目录 0700、socket 0600），协议是 JSON 行：
//   扩展 → CuePad  hello（连接后第一条，含当前状态与 info 快照）/ state（仅状态切换）/ info（会话名、首条消息、近况变化）/ ack / bye
//   CuePad → 扩展  send（文字+图片，steer/followUp）/ paste（放进输入框）
// 只在 tui/rpc 模式启用；无客户端时不做任何 socket 写入。

import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { execFile } from "node:child_process";

const EXTENSION_VERSION = 5;
const PROTOCOL_VERSION = 1;

/** sun_path 上限 104 字节（含结尾 NUL） */
const SUN_PATH_LIMIT = 104;
/** 一行命令（含 base64 图片）的上限，超过就断开该客户端 */
const MAX_LINE_BYTES = 64 * 1024 * 1024;
/** 工具状态里一句话详情的字符数上限（含省略号） */
const DETAIL_LIMIT = 120;
/** 上报首条用户消息的字符数上限：它只用来当单行显示名，界面与 Pi 自己的会话列表都只显示一行，
 * 不必把可能几 MB 的首条消息（贴入的日志、代码）在每次连接与同步时传来传去。与 CuePi 的 `PiSessionName.firstMessageLimit` 相同。 */
const FIRST_MESSAGE_LIMIT = 200;
/** 近况的字符数上限（含省略号）：手机打开会话时看的最后提问、最终回答与待确认的问题，不同步完整对话 */
const PROMPT_LIMIT = 500;
const REPLY_LIMIT = 1200;
const QUESTION_LIMIT = 500;
/** 标记已经包装过的 ui 对象 */
const CAPTURED = Symbol("cuepad.captured");
/** 进程内子会话的登记表。Pi 的扩展加载器会为每个会话重新求值本模块，所以挂在进程唯一的 globalThis 上 */
const SUBSESSIONS = Symbol.for("cuepad.bridge.subsessions");
/** 子代理会话文件所在目录名：`<父会话文件所在目录>/subagents/`（FireCode 的约定） */
const SUBAGENTS_DIRECTORY = "subagents";
/** 扩展投进会话的机器消息：整条文字只由一个或多个 `<名字>\n…\n</名字>` 块组成
 * （如 FireCode 的 `<firecode_master_event>`、`<firecode_watcher>`、`<firecode_review>`）。它不是你说的话。
 * 块正文止于第一个同名闭合标签：块与块之间夹着真人文字时整条不匹配 */
const MACHINE_MESSAGE = /^(?:<([A-Za-z][\w.-]*)>\n(?:(?!\n<\/\1>)[\s\S])*\n<\/\1>\s*)+$/u;
/** FireCode 把子代理名写在子会话系统提示的这个标签上 */
const WORKER_NAME = /<firecode_worker name="([^"]+)">/u;
/** 交给 CuePad 用来定位终端的环境变量 */
const TERMINAL_ENV_KEYS = [
	"TERM_PROGRAM", "TERM_PROGRAM_VERSION", "__CFBundleIdentifier", "TERM_SESSION_ID", "ITERM_SESSION_ID",
	"TMUX", "TMUX_PANE", "WEZTERM_PANE", "KITTY_WINDOW_ID", "HERDR_PANE_ID",
];

type State =
	| { kind: "idle" }
	| { kind: "thinking" }
	| { kind: "outputting" }
	| { kind: "tool"; tool: string; tools: string[]; detail?: string }
	| { kind: "waiting_user"; promptKind: string; title?: string }
	| { kind: "done"; aborted: boolean }
	| { kind: "error"; error: string };

/** 事件只更新变量，对外状态只由 derive() 推导。 */
class StateTracker {
	active = false;
	phase: "thinking" | "outputting" = "thinking";
	tools = new Map<string, { name: string; detail?: string }>();
	prompt: { kind: string; title?: string } | null = null;
	/** agent_end 记录结果，agent_settled 才生效：重试/压缩/排队消息都可能在 agent_end 之后继续 */
	outcome: State = { kind: "done", aborted: false };
	settled: State | null = null;

	derive(): State {
		if (this.prompt) return { kind: "waiting_user", promptKind: this.prompt.kind, title: this.prompt.title };
		if (this.active) {
			if (this.tools.size > 0) {
				const running = [...this.tools.values()];
				const latest = running[running.length - 1];
				return { kind: "tool", tool: latest.name, tools: running.map((t) => t.name), detail: latest.detail };
			}
			return { kind: this.phase };
		}
		return this.settled ?? { kind: "idle" };
	}
}

/** 只上报一句话摘要，不上报完整参数：命令/搜索模式取首个非空行，文件类工具取文件名，超长截断。 */
function toolDetail(args: any): string | undefined {
	const raw = typeof args?.command === "string" ? args.command
		: typeof args?.pattern === "string" ? args.pattern
		: typeof args?.path === "string" ? path.basename(args.path) : undefined;
	const line = raw?.split("\n").map((l) => l.trim()).find((l) => l.length > 0);
	if (!line) return undefined;
	const chars = Array.from(line);
	return chars.length <= DETAIL_LIMIT ? line : chars.slice(0, DETAIL_LIMIT - 1).join("") + "…";
}

/** 目录必须是"当前用户的 0700 目录"，否则拒绝（/tmp 下的目录可能被他人预先创建）。 */
function ensureSecureDirectory(dir: string): void {
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	const st = fs.lstatSync(dir);
	if (!st.isDirectory() || st.uid !== process.getuid!() || (st.mode & 0o777) !== 0o700) {
		throw new Error(`${dir} is not a directory owned by you with mode 0700`);
	}
}

/** 消息的文字部分（文字块用空格连接），与 Pi 会话列表取首条消息的方式一致。 */
function messageText(message: any): string {
	const content = message?.content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.filter((block: any) => block?.type === "text").map((block: any) => block.text).join(" ");
}

function preview(text: string): string | null {
	return text ? Array.from(text).slice(0, FIRST_MESSAGE_LIMIT).join("") : null;
}

/** 去掉首尾空白后截到 limit 个字符（超出的以省略号结尾）；空文字为 null。 */
function clip(text: string, limit: number): string | null {
	const chars = Array.from(text.trim());
	if (chars.length === 0) return null;
	return chars.length <= limit ? chars.join("") : chars.slice(0, limit - 1).join("") + "…";
}

function isMachineMessage(message: any): boolean {
	return MACHINE_MESSAGE.test(messageText(message).trim());
}

function promptText(message: any): string | null {
	return clip(messageText(message).replace(/[\s\p{Cc}]+/gu, " "), PROMPT_LIMIT);
}

/** 助手消息的回答文字：只取文字块（思考与工具调用不算），保留换行。 */
function replyText(message: any): string | null {
	const blocks = Array.isArray(message?.content) ? message.content : [];
	return clip(blocks.filter((block: any) => block?.type === "text").map((block: any) => block.text).join("\n"), REPLY_LIMIT);
}

/** 当前分支上最后一条符合条件的消息（恢复会话时补回近况）。 */
function lastMessage(entries: any[], matches: (message: any) => boolean): any {
	for (let i = entries.length - 1; i >= 0; i--) {
		if (entries[i]?.type === "message" && matches(entries[i].message)) return entries[i].message;
	}
	return undefined;
}

type Subsession = { directory: string; name: string; kind: string };
type Registry = { sessions: Map<string, Subsession>; listeners: Set<() => void> };
const registry: Registry = ((globalThis as any)[SUBSESSIONS] ??= { sessions: new Map(), listeners: new Set() });

function publishSubsessions() {
	for (const listener of registry.listeners) listener();
}

/** 会话里第一条用户消息（按文件顺序，与 Pi 会话列表一致）。 */
function firstUserMessage(entries: any[]): string | null {
	for (const entry of entries) {
		if (entry?.type !== "message" || entry.message?.role !== "user") continue;
		const text = messageText(entry.message);
		if (text) return preview(text);
	}
	return null;
}

function readTTY(): Promise<string | null> {
	return new Promise((resolve) => {
		execFile("ps", ["-o", "tty=", "-p", String(process.pid)], { encoding: "utf8" }, (error, stdout) => {
			const tty = error ? "" : stdout.trim();
			resolve(tty && tty !== "??" ? tty : null);
		});
	});
}

export default function (pi: any) {
	const socketDirectory = process.env.CUEPAD_PI_SOCKET_DIR ?? `/tmp/cuepad-${process.getuid!()}`;

	let ctx: any;
	let server: net.Server | undefined;
	let socketPath: string | undefined;
	let tty: Promise<string | null> = Promise.resolve(null);
	let tracker = new StateTracker();
	const clients = new Set<net.Socket>();
	let lastKey = "";
	let since = Date.now();
	/** 会话名（`/name`）与首条用户消息：CuePad 据此按 Pi 会话列表的规则显示会话；其余是近况 */
	type Info = {
		name: string | null; firstMessage: string | null; lastPrompt: string | null; lastReply: string | null; question: string | null;
		subagents: { name: string; kind: string }[];
	};
	let info: Info = { name: null, firstMessage: null, lastPrompt: null, lastReply: null, question: null, subagents: [] };
	/** 本会话是某个会话的进程内子会话（子代理）时，它在登记表里的键（会话文件路径）：状态只进登记表，不开 socket */
	let subsessionKey: string | undefined;
	let stopWatchingSubsessions: (() => void) | undefined;
	/** 正在弹出的对话框的文案行（标题、说明、选项）。ui_prompt_start 只带标题，选项与说明要在调用时记下 */
	let asking: string[] | null = null;

	const write = (socket: net.Socket, message: object) => {
		if (!socket.destroyed) socket.write(JSON.stringify(message) + "\n");
	};

	/** 状态没变就不发；没有客户端时只维护 lastKey/since，不做任何 I/O。 */
	function commit() {
		const state = tracker.derive();
		const key = JSON.stringify(state);
		if (key === lastKey) return;
		lastKey = key;
		since = Date.now();
		const sub = subsessionKey && registry.sessions.get(subsessionKey);
		if (sub) {
			sub.kind = state.kind;
			publishSubsessions();
		}
		if (clients.size === 0) return;
		const message = { t: "state", state: { ...state, since } };
		for (const client of clients) write(client, message);
	}

	/** 有变化才发。 */
	function updateInfo(changes: Partial<Info>) {
		const next = { ...info, ...changes };
		if (JSON.stringify(next) === JSON.stringify(info)) return;
		info = next;
		for (const client of clients) write(client, { t: "info", ...info });
	}

	async function hello() {
		const terminalEnv: Record<string, string> = {};
		for (const key of TERMINAL_ENV_KEYS) if (process.env[key]) terminalEnv[key] = process.env[key]!;
		return {
			t: "hello",
			protocol: PROTOCOL_VERSION,
			extensionVersion: EXTENSION_VERSION,
			sessionId: ctx.sessionManager.getSessionId(),
			sessionFile: ctx.sessionManager.getSessionFile() ?? null,
			pid: process.pid,
			cwd: ctx.cwd,
			mode: ctx.mode,
			model: ctx.model?.id ?? null,
			tty: await tty,
			term: terminalEnv,
			state: { ...tracker.derive(), since },
			...info,
		};
	}

	// ---- CuePad → 扩展 ----
	function handleCommand(socket: net.Socket, command: any) {
		const ack = (fields: object) => write(socket, { t: "ack", id: command?.id ?? null, ...fields });
		const reject = (error: string) => ack({ ok: false, error });
		try {
			if (command?.t === "send") return handleSend(command, ack, reject);
			if (command?.t === "paste") {
				if (typeof command.text !== "string") return reject("bad_request");
				// RPC 模式下 pasteToEditor 退化为 set_editor_text 请求转给客户端
				ctx.ui.pasteToEditor(command.text);
				// TUI 的 pasteToEditor 不会请求重绘；setStatus 会（清一个不存在的 key 无其他副作用）
				ctx.ui.setStatus("cuepad-repaint", undefined);
				return ack({ ok: true });
			}
			reject("bad_request");
		} catch (error: any) {
			reject(`failed: ${error?.message ?? error}`);
		}
	}

	function handleSend(command: any, ack: (f: object) => void, reject: (e: string) => void) {
		const images: any[] = command.images ?? [];
		const validImages = Array.isArray(images) && images.every((i) => typeof i?.mimeType === "string" && typeof i?.data === "string");
		const text = command.text ?? "";
		const deliverAs = command.deliverAs ?? "followUp";
		if (typeof text !== "string" || !validImages || (deliverAs !== "steer" && deliverAs !== "followUp")) return reject("bad_request");
		if (text.length === 0 && images.length === 0) return reject("empty");

		const content = images.length === 0
			? text
			: [{ type: "text", text }, ...images.map((i) => ({ type: "image", data: i.data, mimeType: i.mimeType }))];
		const busy = !ctx.isIdle();
		// deliverAs 只在会话正忙时生效；总是带上，避免"检查空闲"与"发送"之间 agent 恰好开始而抛错
		pi.sendUserMessage(content, { deliverAs });
		ack({ ok: true, delivered: busy ? deliverAs : "immediate" });
	}

	async function onConnection(socket: net.Socket) {
		socket.on("error", () => socket.destroy());
		const greeting = await hello();
		if (socket.destroyed) return;
		clients.add(socket);
		socket.on("close", () => clients.delete(socket));
		write(socket, greeting);

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
				let command: any;
				try {
					command = JSON.parse(line);
				} catch {
					write(socket, { t: "ack", id: null, ok: false, error: "bad_request" });
					continue;
				}
				handleCommand(socket, command);
			}
		});
	}

	// ---- 生命周期 ----
	function start() {
		stop("restart");
		ensureSecureDirectory(socketDirectory);
		const file = path.join(socketDirectory, `${ctx.sessionManager.getSessionId()}.${process.pid}.sock`);
		if (Buffer.byteLength(file) >= SUN_PATH_LIMIT) throw new Error(`socket path too long: ${file}`);
		fs.rmSync(file, { force: true });
		server = net.createServer((socket) => void onConnection(socket));
		server.on("error", () => {});
		// chmod 既收紧权限，也会产生 FSEvents 能看到的属性变更（仅 bind 的 socket 创建事件不会被报告）
		server.listen(file, () => fs.chmodSync(file, 0o600));
		socketPath = file;
	}

	/** 顶层会话：同进程里会话文件在自己目录的 `subagents/` 下的子会话都是它的子代理，汇总进 info。 */
	function watchSubsessions(file: string | undefined) {
		if (!file) return;
		const directory = path.join(path.dirname(file), SUBAGENTS_DIRECTORY);
		const refresh = () => updateInfo({
			subagents: [...registry.sessions.values()]
				.filter((sub) => sub.directory === directory)
				.map((sub) => ({ name: sub.name, kind: sub.kind })),
		});
		registry.listeners.add(refresh);
		stopWatchingSubsessions = () => registry.listeners.delete(refresh);
		refresh();
	}

	/** print 模式的会话若是子代理（会话文件在 `subagents/` 下）：登记进表，由同进程的顶层会话汇总。 */
	function registerSubsession() {
		const file: string | undefined = ctx.sessionManager.getSessionFile();
		if (!file || path.basename(path.dirname(file)) !== SUBAGENTS_DIRECTORY) return;
		const firstMessage = firstUserMessage(ctx.sessionManager.getEntries());
		const name = pi.getSessionName() ?? WORKER_NAME.exec(ctx.getSystemPrompt?.() ?? "")?.[1] ?? firstMessage ?? path.basename(file, ".jsonl");
		subsessionKey = file;
		registry.sessions.set(file, { directory: path.dirname(file), name, kind: tracker.derive().kind });
		publishSubsessions();
	}

	function unregisterSubsession() {
		if (!subsessionKey) return;
		registry.sessions.delete(subsessionKey);
		subsessionKey = undefined;
		publishSubsessions();
	}

	function stop(reason: string) {
		stopWatchingSubsessions?.();
		stopWatchingSubsessions = undefined;
		for (const client of clients) {
			write(client, { t: "bye", reason });
			client.end();
		}
		clients.clear();
		server?.close();
		server = undefined;
		if (socketPath) fs.rmSync(socketPath, { force: true });
		socketPath = undefined;
	}
	process.on("exit", () => socketPath && fs.rmSync(socketPath, { force: true }));

	/** 包装所有扩展共用的 ui 对象上的对话框方法，记下文案后照常调用（Pi 每次绑定界面都换新对象，session_start 前绑定）。 */
	function captureDialogs(ui: any) {
		if (!ui || ui[CAPTURED]) return;
		ui[CAPTURED] = true;
		const wrap = (method: string, lines: (...args: any[]) => unknown[]) => {
			const original = ui[method];
			if (typeof original !== "function") return;
			ui[method] = (...args: any[]) => {
				// 嵌套弹窗只算最外层，与 ui_prompt_start 一致
				asking ??= lines(...args).filter((line): line is string => typeof line === "string" && line.length > 0);
				return original.apply(ui, args);
			};
		};
		wrap("select", (title, options) => [title, ...(Array.isArray(options) ? options : [])]);
		wrap("confirm", (title, message) => [title, message]);
		wrap("input", (title) => [title]);
		wrap("editor", (title) => [title]);
	}

	pi.on("session_start", (_event: any, context: any) => {
		ctx = context;
		tracker = new StateTracker();
		lastKey = JSON.stringify(tracker.derive());
		since = Date.now();
		// print/json 是没有输入框的运行：一次性的 pi -p，或其他扩展在同进程里开的子会话（FireCode 子代理）。
		// 都不作为会话出现；子代理的状态汇总到父会话
		if (ctx.mode !== "tui" && ctx.mode !== "rpc") return registerSubsession();
		tty = readTTY();
		const branch = ctx.sessionManager.getBranch();
		info = {
			name: pi.getSessionName() ?? null,
			firstMessage: firstUserMessage(ctx.sessionManager.getEntries()),
			lastPrompt: promptText(lastMessage(branch, (m) => m?.role === "user" && !isMachineMessage(m))),
			lastReply: replyText(lastMessage(branch, (m) => m?.role === "assistant")),
			question: null,
			subagents: [],
		};
		asking = null;
		captureDialogs(ctx.ui);
		try {
			start();
			watchSubsessions(ctx.sessionManager.getSessionFile());
		} catch (error: any) {
			ctx.ui.notify(`CuePad bridge disabled: ${error?.message ?? error}`, "warning");
		}
	});
	pi.on("session_shutdown", (event: any) => {
		unregisterSubsession();
		stop(event.reason);
	});
	pi.on("session_info_changed", (event: any) => updateInfo({ name: event.name ?? null }));
	pi.on("message_end", (event: any) => {
		if (event.message?.role !== "user") return;
		// 首条消息与 Pi 会话列表一致，不区分机器消息
		const firstMessage = info.firstMessage ?? preview(messageText(event.message));
		updateInfo(isMachineMessage(event.message) ? { firstMessage } : { firstMessage, lastPrompt: promptText(event.message) });
	});

	// ---- Pi 事件 → 状态 ----
	pi.on("agent_start", () => {
		tracker.active = true;
		tracker.phase = "thinking";
		tracker.settled = null;
		tracker.outcome = { kind: "done", aborted: false };
		commit();
	});
	pi.on("turn_start", () => { tracker.phase = "thinking"; commit(); });
	pi.on("message_update", (event: any) => {
		const type = event.assistantMessageEvent.type;
		const next = type === "text_delta" ? "outputting" : type === "thinking_delta" ? "thinking" : tracker.phase;
		if (next === tracker.phase) return;
		tracker.phase = next;
		commit();
	});
	pi.on("tool_execution_start", (event: any) => { tracker.tools.set(event.toolCallId, { name: event.toolName, detail: toolDetail(event.args) }); commit(); });
	pi.on("tool_execution_end", (event: any) => { tracker.tools.delete(event.toolCallId); tracker.phase = "thinking"; commit(); });
	pi.on("ui_prompt_start", (event: any) => {
		tracker.prompt = { kind: event.kind, title: event.title };
		updateInfo({ question: clip((asking ?? [event.title ?? ""]).join("\n"), QUESTION_LIMIT) });
		commit();
	});
	pi.on("ui_prompt_end", () => {
		tracker.prompt = null;
		asking = null;
		updateInfo({ question: null });
		commit();
	});
	pi.on("agent_end", (event: any) => {
		const last = [...event.messages].reverse().find((m: any) => m.role === "assistant");
		updateInfo({ lastReply: replyText(last) });
		if (last?.stopReason === "error") tracker.outcome = { kind: "error", error: last.errorMessage ?? "unknown" };
		else if (last?.stopReason === "aborted") tracker.outcome = { kind: "done", aborted: true };
	});
	pi.on("agent_settled", () => {
		tracker.active = false;
		tracker.tools.clear();
		tracker.settled = tracker.outcome;
		commit();
	});
}
