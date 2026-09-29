// CuePad Pi bridge extension
// 由 CuePad 安装到 Pi 扩展目录，升级时整文件覆盖，请勿手改。协议说明见 docs/swift-rewrite.md「Pi 桥」。
//
// 每个 Pi 会话在 socket 目录开一个 `<sessionId>.<pid>.sock`（目录 0700、socket 0600），协议是 JSON 行：
//   扩展 → CuePad  hello（连接后第一条，含当前状态快照）/ state（仅状态切换）/ ack / bye
//   CuePad → 扩展  send（文字+图片，steer/followUp）/ paste（放进输入框）
// 只在 tui/rpc 模式启用；无客户端时不做任何 socket 写入。

import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { execFile } from "node:child_process";

const EXTENSION_VERSION = 1;
const PROTOCOL_VERSION = 1;

/** sun_path 上限 104 字节（含结尾 NUL） */
const SUN_PATH_LIMIT = 104;
/** 一行命令（含 base64 图片）的上限，超过就断开该客户端 */
const MAX_LINE_BYTES = 64 * 1024 * 1024;
/** 交给 CuePad 用来定位终端的环境变量 */
const TERMINAL_ENV_KEYS = [
	"TERM_PROGRAM", "TERM_PROGRAM_VERSION", "__CFBundleIdentifier", "TERM_SESSION_ID", "ITERM_SESSION_ID",
	"TMUX", "TMUX_PANE", "WEZTERM_PANE", "KITTY_WINDOW_ID", "HERDR_PANE_ID",
];

type State =
	| { kind: "idle" }
	| { kind: "thinking" }
	| { kind: "outputting" }
	| { kind: "tool"; tool: string; tools: string[] }
	| { kind: "waiting_user"; promptKind: string; title?: string }
	| { kind: "done"; aborted: boolean }
	| { kind: "error"; error: string };

/** 事件只更新变量，对外状态只由 derive() 推导。 */
class StateTracker {
	active = false;
	phase: "thinking" | "outputting" = "thinking";
	tools = new Map<string, string>();
	prompt: { kind: string; title?: string } | null = null;
	/** agent_end 记录结果，agent_settled 才生效：重试/压缩/排队消息都可能在 agent_end 之后继续 */
	outcome: State = { kind: "done", aborted: false };
	settled: State | null = null;

	derive(): State {
		if (this.prompt) return { kind: "waiting_user", promptKind: this.prompt.kind, title: this.prompt.title };
		if (this.active) {
			if (this.tools.size > 0) {
				const names = [...this.tools.values()];
				return { kind: "tool", tool: names[names.length - 1], tools: names };
			}
			return { kind: this.phase };
		}
		return this.settled ?? { kind: "idle" };
	}
}

/** 目录必须是"当前用户的 0700 目录"，否则拒绝（/tmp 下的目录可能被他人预先创建）。 */
function ensureSecureDirectory(dir: string): void {
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	const st = fs.lstatSync(dir);
	if (!st.isDirectory() || st.uid !== process.getuid!() || (st.mode & 0o777) !== 0o700) {
		throw new Error(`${dir} is not a directory owned by you with mode 0700`);
	}
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
		if (clients.size === 0) return;
		const message = { t: "state", state: { ...state, since } };
		for (const client of clients) write(client, message);
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

	function stop(reason: string) {
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

	pi.on("session_start", (_event: any, context: any) => {
		ctx = context;
		// print/json 是一次性的无界面运行（脚本、其他工具调用 pi -p），没有输入框也不该出现在会话列表里
		if (ctx.mode !== "tui" && ctx.mode !== "rpc") return;
		tracker = new StateTracker();
		lastKey = JSON.stringify(tracker.derive());
		since = Date.now();
		tty = readTTY();
		try {
			start();
		} catch (error: any) {
			ctx.ui.notify(`CuePad bridge disabled: ${error?.message ?? error}`, "warning");
		}
	});
	pi.on("session_shutdown", (event: any) => stop(event.reason));

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
	pi.on("tool_execution_start", (event: any) => { tracker.tools.set(event.toolCallId, event.toolName); commit(); });
	pi.on("tool_execution_end", (event: any) => { tracker.tools.delete(event.toolCallId); tracker.phase = "thinking"; commit(); });
	pi.on("ui_prompt_start", (event: any) => { tracker.prompt = { kind: event.kind, title: event.title }; commit(); });
	pi.on("ui_prompt_end", () => { tracker.prompt = null; commit(); });
	pi.on("agent_end", (event: any) => {
		const last = [...event.messages].reverse().find((m: any) => m.role === "assistant");
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
