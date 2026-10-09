// CuePad Pi bridge extension
// 由 CuePad 安装到 Pi 扩展目录，升级时整文件覆盖，请勿手改。协议说明见 apple/CuePadKit/Sources/CuePi/README.md。
//
// 每个 Pi 会话在 socket 目录开一个 `<sessionId>.<pid>.sock`（目录 0700、socket 0600），协议是 JSON 行：
//   扩展 → CuePad  hello（连接后第一条，含当前状态与 info 快照）/ state（仅状态切换）/ info（会话名、首条消息、近况变化）/ ack / bye
//   CuePad → 扩展  send（文字+图片，steer/followUp）/ command（斜杠命令，由 Pi 展开执行）/ answer（回答等你确认的弹窗）/ config（会话名、模型、思考强度）/ end（结束会话）/ abort（停止这一轮）
// 只在 tui/rpc 模式启用；无客户端时不做任何 socket 写入。

import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";

const EXTENSION_VERSION = 21;
const PROTOCOL_VERSION = 9;

/** sun_path 上限 104 字节（含结尾 NUL） */
const SUN_PATH_LIMIT = 104;
/** 一行命令（含 base64 图片）的上限，超过就断开该客户端 */
const MAX_LINE_BYTES = 64 * 1024 * 1024;
/** 工具状态里一句话详情的字符数上限（含省略号） */
const DETAIL_LIMIT = 120;
/** 上报首条用户消息的字符数上限：它只用来当单行显示名，界面与 Pi 自己的会话列表都只显示一行，
 * 不必把可能几 MB 的首条消息（贴入的日志、代码）在每次连接与同步时传来传去。与 CuePi 的 `PiSessionName.firstMessageLimit` 相同。 */
const FIRST_MESSAGE_LIMIT = 200;
/** 等你回答的弹窗文案的字符数上限（含省略号） */
const QUESTION_LIMIT = 500;
/** 标记已经包装过的 ui 对象 */
const CAPTURED = Symbol("cuepad.captured");
/** FireCode 发布"在飞子代理数"的频道（`{ inFlight }`）：在跑、在审，或已落定但结果事件还没交给指挥官的都算。
 * 与 FireCode 判断"会话进行中"用同一个事实 */
const FIRECODE_WORKERS_CHANNEL = "firecode:workers";
/** FireCode 发布子代理名册的频道（`{ workers }`，整份、内容变了才发，停用发空名册）：角色、状态、在做什么与时刻都取自它，
 * 不读 FireCode 的档案或会话文件 */
const FIRECODE_SUBAGENTS_CHANNEL = "firecode:subagents";
/** 子代理"在做什么"一句话的字符数上限（含省略号） */
const SUBAGENT_ACTION_LIMIT = 120;
/** CuePad 在终端里开新会话时经这个环境变量交给扩展的认领标识，扩展在 hello 里带回 */
const LAUNCH_TOKEN_ENV = "CUEPAD_LAUNCH_TOKEN";
/** 需要"命令上下文"（切换会话、新会话、重载、克隆）的操作只能在命令处理函数里做：本扩展注册这一条内部命令 `/cuepad <动作>`，
 * 经 `sendUserMessage("/cuepad <动作>", { expandPromptTemplates: true })` 触发。只有这条内部命令本身不列进给手机的清单；
 * 内置的 /new、/clone、/reload 照常在清单里（`BUILTIN_COMMANDS`），执行时才转到它。 */
const INTERNAL_COMMAND = "cuepad";
/** 压缩命令受理后等多久：这段时间内失败算命令失败，之后只提示在 Pi 里 */
const COMPACT_FAILURE_WINDOW_MS = 1500;
/** 命令清单里每条说明的字符数上限（含省略号）：skill 的说明可以很长，清单随会话记录同步，只要够选命令用 */
const COMMAND_DESCRIPTION_LIMIT = 120;
/** Pi 内置斜杠命令里能在非 TUI 下执行的（其余是终端里的选择器、弹窗或只往终端打印，没有对应接口，不列）。
 * `hint` 有值表示带参数（`required` 为必填）。名字、说明与 Pi 的 `/` 菜单一致。
 * 内置命令在 Pi 的终端里先于扩展命令匹配，这里同样先匹配。 */
const BUILTIN_COMMANDS = [
	{ name: "compact", description: "压缩当前上下文，可附上说明", hint: "[说明]" },
	{ name: "name", description: "设置会话名", hint: "<名字>", required: true },
	{ name: "model", description: "换模型", hint: "<提供方/模型>", required: true },
	{ name: "thinking", description: "设置思考强度", hint: "<强度>", required: true },
	{ name: "new", description: "开一个新会话" },
	{ name: "clone", description: "在当前位置复制出一个新会话" },
	{ name: "reload", description: "重新载入扩展、skill、提示词模板与上下文文件" },
] as const;
type BuiltinCommand = (typeof BUILTIN_COMMANDS)[number];
/** 会话文件里的条目数（不算文件头） */
function entriesOnDisk(file: string): number {
	return fs.readFileSync(file, "utf8").split("\n").filter((line) => line.trim().length > 0).length - 1;
}
/** CuePad 在后台托管的 Pi（RPC 模式、没有终端界面）启动时带这个环境变量，扩展在 hello 里带回 */
const HOSTED_ENV = "CUEPAD_HOSTED";
/** Pi 的思考强度，由弱到强（pi-ai 的 `ModelThinkingLevel`） */
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
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
	/** 自己这轮已经歇下，还有子代理在飞：仍在处理 */
	| { kind: "delegating" }
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
	/** 在飞子代理数（FireCode 发布） */
	inFlight = 0;

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
		if (this.inFlight > 0) return { kind: "delegating" };
		return this.settled ?? { kind: "idle" };
	}
}

type Phase = "working" | "waiting" | "error" | "idle";

/** 粗状态：计时只在它变化时动，思考、工具、等子代理之间切换不算。 */
function phaseOf(state: State): Phase {
	switch (state.kind) {
		case "thinking": case "outputting": case "tool": case "delegating": return "working";
		case "waiting_user": return "waiting";
		case "error": return "error";
		default: return "idle";
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

/** 手机上看的一个子代理：`state` 是 FireCode 名册的状态原文（running/review/done/failed/interrupted/idle），时刻是毫秒 */
type Subagent = { name: string; role: string; state: string; action: string; startedAt: number | null; settledAt: number | null };

function subagentsOf(workers: unknown): Subagent[] {
	if (!Array.isArray(workers)) return [];
	return workers.map((worker: any) => ({
		name: String(worker.name),
		role: String(worker.role),
		state: String(worker.state),
		action: clip(String(worker.action ?? ""), SUBAGENT_ACTION_LIMIT) ?? "",
		startedAt: typeof worker.startedAt === "number" ? worker.startedAt : null,
		settledAt: typeof worker.settledAt === "number" ? worker.settledAt : null,
	}));
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

/** 模型支持的思考强度，与 pi-ai 的 `getSupportedThinkingLevels` 同一规则（只读模型的公开字段，不引入对 pi-ai 的依赖）：
 * 不支持思考的只有 off，`thinkingLevelMap` 里为 null 的不支持，xhigh、max 要模型显式声明。设置时 Pi 本来就会按模型夹取，这里只决定给手机列哪些。 */
function thinkingLevels(model: any): string[] {
	if (!model.reasoning) return ["off"];
	return THINKING_LEVELS.filter((level) => {
		const mapped = model.thinkingLevelMap?.[level];
		if (mapped === null) return false;
		return level === "xhigh" || level === "max" ? mapped !== undefined : true;
	});
}

function describeModel(model: any) {
	return { provider: model.provider, id: model.id, name: model.name ?? model.id, thinking: thinkingLevels(model) };
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
	/** 只属于这个进程里的第一个会话：读走后清掉，之后 /new 开的会话与进程内子会话都不带 */
	let launchToken: string | null = process.env[LAUNCH_TOKEN_ENV] || null;
	delete process.env[LAUNCH_TOKEN_ENV];

	let ctx: any;
	let server: net.Server | undefined;
	let socketPath: string | undefined;
	let tty: Promise<string | null> = Promise.resolve(null);
	let tracker = new StateTracker();
	const clients = new Set<net.Socket>();
	let lastKey = "";
	let phase: Phase = "idle";
	/** 进入当前粗状态的时间 */
	let since = Date.now();
	/** 这段连续处理（离开空闲到彻底歇下，中间等你确认也算）开始的时间；空闲、出错时为 null */
	let busySince: number | null = null;
	/** 会话名（`/name`）与首条用户消息：CuePad 据此按 Pi 会话列表的规则显示会话；其余是近况 */
	type Info = {
		name: string | null; firstMessage: string | null; question: Question | null;
		subagents: Subagent[];
		/** 当前模型、思考强度与可换的模型（Pi 里已配好密钥的）：手机据此选 */
		model: ReturnType<typeof describeModel> | null; thinking: string | null; models: ReturnType<typeof describeModel>[];
		/** 上下文余量：已用 token（压缩后到下一次回答前未知，为 null）与当前模型的窗口；没有模型为 null */
		context: { tokens: number | null; window: number } | null;
		/** 此刻能用的斜杠命令：能执行的内置命令 + 扩展命令 + 提示词模板 + skill */
		commands: CommandInfo[];
	};
	type CommandInfo = { name: string; description: string | null; source: "builtin" | "extension" | "prompt" | "skill"; hint: string | null };
	/** 等你回答的弹窗：`id` 非空的可以从 CuePad 作答（confirm/select/text）；editor 与 custom 只能在 Pi 里答 */
	type Question = { id: string | null; kind: string; text: string; options: string[] };
	/** 会话载入时的条目数：之后多出来的是这个进程自己写的 */
	let loadedEntries = 0;
	let info: Info = { name: null, firstMessage: null, question: null, subagents: [], model: null, thinking: null, models: [], context: null, commands: [] };
	/** CuePad 送进来、还没落成会话里一条消息的投送请求：文字 → 请求 id，按发出的先后（同一文字发了两次时先发的先认领） */
	const deliveries: { text: string; id: string }[] = [];
	/** 正在弹出的对话框（最外层）。ui_prompt_start 只带标题，说明与选项要在调用时记下；`settle` 从 CuePad 作答 */
	let asking: (Question & { settle?: (value: unknown) => void; dismiss?: () => void }) | null = null;

	const write = (socket: net.Socket, message: object) => {
		if (!socket.destroyed) socket.write(JSON.stringify(message) + "\n");
	};

	/** 状态没变就不发；没有客户端时只维护状态与计时，不做任何 I/O。 */
	function commit() {
		const state = tracker.derive();
		const key = JSON.stringify(state);
		if (key === lastKey) return;
		lastKey = key;
		const next = phaseOf(state);
		if (next !== phase) {
			const now = Date.now();
			since = now;
			busySince = next === "working" || next === "waiting" ? busySince ?? now : null;
			phase = next;
		}
		if (clients.size === 0) return;
		const message = { t: "state", state: { ...state, since, busySince } };
		for (const client of clients) write(client, message);
	}

	/** 有变化才发。 */
	function updateInfo(changes: Partial<Info>) {
		const next = { ...info, ...changes };
		if (JSON.stringify(next) === JSON.stringify(info)) return;
		info = next;
		for (const client of clients) write(client, { t: "info", ...info });
	}

	/** 此刻的模型配置；Pi 里换了模型、强度后重新取。可选的模型与 Pi 的 /model 一致：配了范围（`--models`、`enabledModels`）就是范围内的，
	 * 否则是已配好密钥的全部；当前模型总在其中。 */
	function modelChoices(): any[] {
		const scoped: any[] = (ctx.scopedModels ?? []).map((entry: any) => entry.model);
		const choices: any[] = scoped.length > 0 ? scoped : ctx.modelRegistry.getAvailable();
		const current = ctx.model;
		return current && !choices.some((m) => m.provider === current.provider && m.id === current.id) ? [...choices, current] : choices;
	}

	function modelInfo(): Pick<Info, "model" | "thinking" | "models"> {
		const current = ctx.model;
		return {
			model: current ? describeModel(current) : null,
			thinking: current ? pi.getThinkingLevel() : null,
			models: modelChoices().map(describeModel),
		};
	}

	/** 上下文余量：Pi 估算的已用 token 与当前模型的窗口（压缩后到下一次回答前 tokens 为 null）。 */
	function contextInfo(): Pick<Info, "context"> {
		const usage = ctx.getContextUsage();
		return { context: usage ? { tokens: usage.tokens, window: usage.contextWindow } : null };
	}

	/** 此刻的命令清单。扩展命令与内置同名时内置先匹配（与 Pi 的终端一致），同名的扩展命令用不到，不列。 */
	function commandInfo(): Pick<Info, "commands"> {
		const builtin: CommandInfo[] = BUILTIN_COMMANDS.map((c) => ({
			name: c.name, description: c.description, source: "builtin", hint: "hint" in c ? c.hint : null,
		}));
		const taken = new Set<string>([INTERNAL_COMMAND, ...BUILTIN_COMMANDS.map((c) => c.name)]);
		const resources: CommandInfo[] = pi.getCommands().filter((c: any) => !taken.has(c.name)).map((c: any) => ({
			name: c.name, description: clip(String(c.description ?? "").replace(/\s+/g, " "), COMMAND_DESCRIPTION_LIMIT), source: c.source, hint: null,
		}));
		return { commands: [...builtin, ...resources] };
	}

	/** 上下文与命令清单会随每一轮、压缩、换模型、重载变化；有变化才发。 */
	function refreshUsage() {
		if (server) updateInfo({ ...contextInfo(), ...commandInfo() });
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
			tty: await tty,
			term: terminalEnv,
			state: { ...tracker.derive(), since, busySince },
			launchToken,
			hosted: process.env[HOSTED_ENV] === "1",
			...info,
		};
	}

	// ---- CuePad → 扩展 ----
	function handleCommand(socket: net.Socket, command: any) {
		const ack = (fields: object) => write(socket, { t: "ack", id: command?.id ?? null, ...fields });
		const reject = (error: string) => ack({ ok: false, error });
		try {
			if (command?.t === "send") return handleSend(command, ack, reject);
			if (command?.t === "command") return void handleSlash(command, ack, reject).catch((error: any) => reject(`failed: ${error?.message ?? error}`));
			if (command?.t === "answer") return handleAnswer(command, ack, reject);
			if (command?.t === "reload") return handleReload(ack);
			if (command?.t === "end") return handleEnd(ack);
			if (command?.t === "abort") return handleAbort(ack);
			if (command?.t === "config") return void handleConfig(command, ack, reject).catch((error: any) => reject(`failed: ${error?.message ?? error}`));
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
		if (typeof command.deliveryId === "string") deliveries.push({ text, id: command.deliveryId });
		// deliverAs 只在会话正忙时生效；总是带上，避免"检查空闲"与"发送"之间 agent 恰好开始而抛错
		pi.sendUserMessage(content, { deliverAs });
		ack({ ok: true, delivered: busy ? deliverAs : "immediate" });
	}

	/**
	 * CuePad 在后台托管的同一会话刚做完一轮、让出退出：那一轮写进会话文件的内容，这个进程（用户打开时已载入）看不到。
	 * 这个进程从载入起没写过，就把会话从文件重新载入到最新——之后说的话接在那一轮后面，不分支；写过了（会话已分出支线）
	 * 就不动，提示一句。Pi 只在命令里给切换会话的能力（`switchSession`），所以经 `sendUserMessage` 触发本扩展的命令。
	 */
	function handleReload(ack: (f: object) => void) {
		const file: string | undefined = ctx.sessionManager.getSessionFile();
		const inMemory = ctx.sessionManager.getEntries().length;
		if (!file || entriesOnDisk(file) <= inMemory) return ack({ ok: true, reloaded: false });
		if (inMemory !== loadedEntries || !ctx.isIdle()) {
			ctx.ui.notify("CuePad 在后台跑的那一轮在你打开会话后才写完，会话分出了支线；用 /tree 查看", "warning");
			return ack({ ok: true, reloaded: false });
		}
		ack({ ok: true, reloaded: true });
		runInternal("reload-session");
	}

	/** 下一轮事件循环再触发：重载、新会话会拆掉本扩展实例并关掉连接，`ack` 要先写出去。 */
	function runInternal(action: string) {
		setImmediate(() => pi.sendUserMessage(`/${INTERNAL_COMMAND} ${action}`, { expandPromptTemplates: true }));
	}

	pi.registerCommand(INTERNAL_COMMAND, {
		description: "CuePad 内部使用：需要命令上下文的会话操作（重新载入会话文件、新会话、重载、克隆）",
		handler: async (action: string, command: any) => {
			switch (action.trim()) {
				case "reload-session": {
					const file = command.sessionManager.getSessionFile();
					if (file) await command.switchSession(file);
					break;
				}
				case "new": await command.newSession(); break;
				case "reload": await command.reload(); break;
				case "clone": {
					const leaf = command.sessionManager.getLeafId();
					if (leaf) await command.fork(leaf, { position: "at" });
					break;
				}
			}
		},
	});

	/**
	 * 斜杠命令：内置的（能在非 TUI 下执行的）由本扩展调 Pi 的接口做，其余（扩展命令、提示词模板、skill）经
	 * `sendUserMessage(…, { expandPromptTemplates: true })` 交给 Pi 派发——扩展命令执行（会话正忙也立即执行）、模板与 skill 展开成这一轮的提示词；
	 * 不带这个选项的 `sendUserMessage` 只把它当普通文字。清单里没有的名字拒绝，不当文字发出去。
	 * `ack` 表示已受理：扩展命令的执行结果与报错只出现在 Pi 自己的界面（`ctx.ui`），这里看不到。
	 */
	async function handleSlash(command: any, ack: (f: object) => void, reject: (e: string) => void) {
		const text = command.text;
		const deliverAs = command.deliverAs ?? "followUp";
		if (typeof text !== "string" || !text.startsWith("/") || (deliverAs !== "steer" && deliverAs !== "followUp")) return reject("bad_request");
		const space = text.search(/\s/);
		const name = text.slice(1, space < 0 ? undefined : space);
		const args = space < 0 ? "" : text.slice(space + 1).trim();
		const builtin = BUILTIN_COMMANDS.find((c) => c.name === name);
		if (builtin) {
			const error = await runBuiltin(builtin, args);
			return error ? reject(error) : ack({ ok: true });
		}
		if (name === INTERNAL_COMMAND || !pi.getCommands().some((c: any) => c.name === name)) return reject("unknown_command");
		pi.sendUserMessage(text, { deliverAs, expandPromptTemplates: true });
		ack({ ok: true });
	}

	/** 执行一条内置命令；返回拒绝原因，成功返回 undefined。 */
	async function runBuiltin(builtin: BuiltinCommand, args: string): Promise<string | undefined> {
		if ("required" in builtin && !args) return "missing_argument";
		switch (builtin.name) {
			case "compact": return compact(args);
			case "name": pi.setSessionName(args); return;
			case "thinking":
				if (!THINKING_LEVELS.includes(args)) return "bad_request";
				pi.setThinkingLevel(args);
				break;
			case "model": {
				const target = findModel(args);
				if (!target) return "unknown_model";
				if (!(await pi.setModel(target))) return "no_auth";
				break;
			}
			case "clone":
				if (!ctx.sessionManager.getLeafId()) return "failed: nothing to clone";
				runInternal("clone");
				return;
			case "new":
			case "reload":
				runInternal(builtin.name);
				return;
		}
		updateInfo({ ...modelInfo(), ...contextInfo() });
	}

	/** 压缩不等完成就返回；开头一小段时间内的失败（没有可压缩的内容、没有模型）当作拒绝报给手机，之后的失败只能提示在 Pi 里。 */
	function compact(instructions: string): Promise<string | undefined> {
		return new Promise((resolve) => {
			const early = setTimeout(() => resolve(undefined), COMPACT_FAILURE_WINDOW_MS);
			ctx.compact({
				customInstructions: instructions || undefined,
				onComplete: () => { clearTimeout(early); resolve(undefined); },
				onError: (error: Error) => {
					clearTimeout(early);
					ctx.ui.notify(`压缩失败：${error.message}`, "error");
					resolve(`failed: ${error.message}`);
				},
			});
		});
	}

	/** `provider/id` 精确匹配，或模型 id 在可选模型里唯一（与 Pi 的 /model 同一份候选）。 */
	function findModel(reference: string): any {
		const models = modelChoices();
		const slash = reference.indexOf("/");
		const exact = slash > 0 ? models.find((m) => m.provider === reference.slice(0, slash) && m.id === reference.slice(slash + 1)) : undefined;
		if (exact) return exact;
		const byId = models.filter((m) => m.id === reference);
		return byId.length === 1 ? byId[0] : undefined;
	}

	/**
	 * 结束会话：与用户在 Pi 里退出同一条路（`ctx.shutdown`——TUI 恢复终端并提示怎么恢复会话，退出时发 `bye quit`）。
	 * 正在跑的一轮先中止、等你回答的弹窗先取消，否则 Pi 要等它们结束才会退出。RPC 模式只在读到下一条命令或这一轮结束时检查退出请求，
	 * 所以后台托管的进程不走这里，由 `PiHost` 关掉标准输入。
	 */
	function handleEnd(ack: (f: object) => void) {
		ack({ ok: true });
		asking?.dismiss?.();
		if (!ctx.isIdle()) ctx.abort();
		ctx.shutdown();
	}

	/**
	 * 停止这一轮：Pi 的 `ctx.abort()`，与用户在 Pi 里按 Esc 同一能力，只中止指挥官自己正在跑的回合，会话随后以"被中止"歇下、等下一句。
	 * 等你回答的弹窗先取消（否则这一轮会一直卡在等你）。已经空闲就什么都不做；FireCode 的子代理是独立会话，不受影响，
	 * 它们落定后照常把结果投回来开始新的一轮。
	 */
	function handleAbort(ack: (f: object) => void) {
		asking?.dismiss?.();
		if (!ctx.isIdle()) ctx.abort();
		ack({ ok: true });
	}

	/** 会话设置：会话名（Pi 设置会话名的接口，同 `/name`）、模型、思考强度——先换模型（需要该提供方已配好密钥）再设强度，强度由 Pi 按新模型支持的范围夹取。 */
	async function handleConfig(command: any, ack: (f: object) => void, reject: (e: string) => void) {
		const { model, thinking } = command;
		const name = typeof command.name === "string" ? command.name.trim() : command.name;
		const validModel = model === undefined || (typeof model?.provider === "string" && typeof model?.id === "string");
		const validThinking = thinking === undefined || THINKING_LEVELS.includes(thinking);
		const validName = name === undefined || (typeof name === "string" && name.length > 0);
		if (!validModel || !validThinking || !validName || (model === undefined && thinking === undefined && name === undefined)) return reject("bad_request");
		if (name) pi.setSessionName(name);
		if (model) {
			const target = ctx.modelRegistry.find(model.provider, model.id);
			if (!target) return reject("unknown_model");
			if (!(await pi.setModel(target))) return reject("no_auth");
		}
		if (thinking) pi.setThinkingLevel(thinking);
		updateInfo(modelInfo());
		ack({ ok: true });
	}

	/** 回答当前弹窗：标识必须是正在等的那个（答过或换了弹窗就拒绝），答案的类型与选项要对得上。 */
	function handleAnswer(command: any, ack: (f: object) => void, reject: (e: string) => void) {
		const pending = asking;
		if (!pending?.settle) return reject("no_prompt");
		if (pending.id !== command.promptId) return reject("stale_prompt");
		const value = command.value;
		const valid = pending.kind === "confirm" ? typeof value === "boolean"
			: pending.kind === "select" ? typeof value === "string" && pending.options.includes(value)
			: typeof value === "string";
		if (!valid) return reject("bad_answer");
		pending.settle(value);
		asking = null;
		ack({ ok: true });
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

	/** 包装所有扩展共用的 ui 对象上的对话框方法（Pi 每次绑定界面都换新对象，session_start 前绑定）：记下文案与选项，
	 * 并给弹窗接上一个由我们控制的 AbortSignal。从 CuePad 作答时先记下答案再 abort：Pi 的界面随之收起
	 * （TUI 隐藏选择器，RPC 删掉待答请求），原调用按"取消"结束，包装把它换成我们的答案交回调用方。 */
	function captureDialogs(ui: any) {
		if (!ui || ui[CAPTURED]) return;
		ui[CAPTURED] = true;
		/** `optionsAt`：对话框选项参数（含 signal）的位置；没有的（editor）不能从外面收起，只记文案 */
		const wrap = (method: string, kind: string, optionsAt: number | null, describe: (...args: any[]) => { lines: unknown[]; options?: unknown }) => {
			const original = ui[method];
			if (typeof original !== "function") return;
			ui[method] = (...args: any[]) => {
				// 嵌套弹窗只算最外层，与 ui_prompt_start 一致
				if (asking) return original.apply(ui, args);
				const { lines, options } = describe(...args);
				const question: Question = {
					id: optionsAt === null ? null : randomUUID(),
					kind,
					text: lines.filter((line): line is string => typeof line === "string" && line.length > 0).join("\n"),
					options: Array.isArray(options) ? options.filter((option): option is string => typeof option === "string") : [],
				};
				if (optionsAt === null) {
					asking = question;
					return original.apply(ui, args);
				}
				// 调用方自己的 signal 与我们的合在一起：任一触发都收起弹窗
				const own = new AbortController();
				const caller: AbortSignal | undefined = args[optionsAt]?.signal;
				let answer: { value: unknown } | undefined;
				asking = { ...question, settle: (value) => { answer = { value }; own.abort(); }, dismiss: () => own.abort() };
				const call = [...args];
				call[optionsAt] = { ...args[optionsAt], signal: caller ? AbortSignal.any([caller, own.signal]) : own.signal };
				return Promise.resolve(original.apply(ui, call)).then((value: unknown) => (answer ? answer.value : value));
			};
		};
		wrap("select", "select", 2, (title, options) => ({ lines: [title], options }));
		wrap("confirm", "confirm", 2, (title, message) => ({ lines: [title, message] }));
		wrap("input", "text", 2, (title) => ({ lines: [title] }));
		wrap("editor", "editor", null, (title) => ({ lines: [title] }));
	}

	pi.on("session_start", (_event: any, context: any) => {
		ctx = context;
		tracker = new StateTracker();
		lastKey = JSON.stringify(tracker.derive());
		phase = "idle";
		since = Date.now();
		busySince = null;
		// print/json 是没有输入框的运行：一次性的 pi -p，或其他扩展在同进程里开的子会话（FireCode 子代理）。都不作为会话出现
		if (ctx.mode !== "tui" && ctx.mode !== "rpc") return;
		tty = readTTY();
		loadedEntries = ctx.sessionManager.getEntries().length;
		info = {
			name: pi.getSessionName() ?? null,
			firstMessage: firstUserMessage(ctx.sessionManager.getEntries()),
			question: null,
			// 名册由 FireCode 在自己的 session_start 里发布，先后不定，不在这里清空；会话换掉时 FireCode 停用会发空名册
			subagents: info.subagents,
			...modelInfo(),
			...contextInfo(),
			...commandInfo(),
		};
		asking = null;
		captureDialogs(ctx.ui);
		try {
			start();
		} catch (error: any) {
			ctx.ui.notify(`CuePad bridge disabled: ${error?.message ?? error}`, "warning");
		}
	});
	pi.on("session_shutdown", (event: any) => {
		launchToken = null;
		stop(event.reason);
	});
	pi.on("model_select", () => { updateInfo(modelInfo()); refreshUsage(); });
	pi.on("thinking_level_select", () => updateInfo(modelInfo()));
	for (const event of ["turn_end", "agent_settled", "session_compact", "session_tree"]) pi.on(event, refreshUsage);
	pi.on("session_info_changed", (event: any) => updateInfo({ name: event.name ?? null }));
	pi.on("message_end", (event: any) => {
		if (event.message?.role !== "user") return;
		// 首条消息与 Pi 会话列表一致，不区分机器消息
		updateInfo({ firstMessage: info.firstMessage ?? preview(messageText(event.message)) });
		// CuePad 送进来的：把投送请求 id 写到这条消息上。扩展先收到 message_end、Pi 再把同一个消息对象写进会话文件，
		// 所以 id 随消息落盘，对话（读会话文件）据此认出它
		const index = deliveries.findIndex((d) => d.text === messageText(event.message));
		if (index >= 0) event.message.cuepadDelivery = deliveries.splice(index, 1)[0].id;
	});

	// ---- Pi 事件 → 状态 ----
	// 提交了一条消息（你的提问，或扩展投进来的，如 FireCode 交回子代理结果）：这一轮从这里开始算。
	// FireCode 交回结果时，在飞数在这之后、agent_start 之前就归零了，从这里接上，连续处理才不会在交接处断开
	pi.on("input", () => {
		if (tracker.active) return;
		tracker.active = true;
		tracker.phase = "thinking";
		commit();
	});
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
		const question = asking ?? { id: null, kind: event.kind, text: event.title ?? "", options: [] };
		updateInfo({ question: { id: question.id, kind: question.kind, text: clip(question.text, QUESTION_LIMIT) ?? "", options: question.options } });
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
		if (last?.stopReason === "error") tracker.outcome = { kind: "error", error: last.errorMessage ?? "unknown" };
		else if (last?.stopReason === "aborted") tracker.outcome = { kind: "done", aborted: true };
	});
	pi.events?.on(FIRECODE_WORKERS_CHANNEL, (data: any) => {
		tracker.inFlight = typeof data?.inFlight === "number" ? data.inFlight : 0;
		commit();
	});
	pi.events?.on(FIRECODE_SUBAGENTS_CHANNEL, (data: any) => updateInfo({ subagents: subagentsOf(data?.workers) }));
	pi.on("agent_settled", () => {
		tracker.active = false;
		tracker.tools.clear();
		tracker.settled = tracker.outcome;
		commit();
	});
}
