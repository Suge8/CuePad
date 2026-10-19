// CuePad Pi bridge extension
// 由 CuePad 安装到 Pi 扩展目录，升级时整文件覆盖，请勿手改。协议说明见 apple/CuePadKit/Sources/CuePi/README.md。
//
// 每个 Pi 会话在 socket 目录开一个 `<sessionId>.<pid>.sock`（目录 0700、socket 0600），协议是 JSON 行：
//   扩展 → CuePad  hello（连接后第一条，含当前状态与 info 快照）/ state（仅状态切换）/ info（变了的那几项：会话名、首条消息、近况）/ draft（正在说的话）/ quota（订阅额度的一次观测）/ ack / bye
//   CuePad → 扩展  send（文字+图片，steer/followUp）/ command（斜杠命令，由 Pi 展开执行）/ answer（回答等你确认的弹窗）/ config（会话名、模型、思考强度）/ end（结束会话）/ abort（停止这一轮）/ quota（查一次订阅额度）
// 只在 tui/rpc 模式启用；无客户端时不做任何 socket 写入。

import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import type {
	ExtensionAPI, ExtensionCommandContext, ExtensionContext, ExtensionUIContext, ExtensionUIDialogOptions, SessionEntry,
} from "@earendil-works/pi-coding-agent";

const EXTENSION_VERSION = 33;
const PROTOCOL_VERSION = 15;

/** 本文件在磁盘上的位置（Pi 经 jiti 载入，按 CommonJS 给出 `__filename`）：CuePad 升级时（`AgentIntegration.install`）把它原子地换成新版本，
 * 见 `reloadWhenIdle` */
const OWN_FILE = __filename;
/** sun_path 上限 104 字节（含结尾 NUL） */
const SUN_PATH_LIMIT = 104;
/** 一行命令（含 base64 图片）的上限，超过就断开该客户端 */
const MAX_LINE_BYTES = 64 * 1024 * 1024;
/** 正在说的话（`draft`）最多每这么久上报一次：增量在这里合并，这条说完时立即补发最后一次 */
const DRAFT_INTERVAL_MS = 100;
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
/** CuePad 问这台 Mac 上的 Pi 能用哪些模型时（`AgentIntegration.probe`）带这个环境变量：会话一开始就把模型配置写成一行
 * `{"cuepadProbe": {model, models}}`，不连 CuePad、不做别的；与会话上报的是同一份（`modelInfo`），没登录时都空。直接写描述符 1：RPC 模式把
 * `process.stdout` 改道到标准错误，护着它的协议输出。不调 `ctx.shutdown()`：RPC 模式只在读到下一条命令时才看退出请求，
 * 进程靠标准输入读到 EOF 退出 */
const PROBE_ENV = "CUEPAD_PROBE";
/** CuePad 在后台托管的 Pi（RPC 模式、没有终端界面）启动时带这个环境变量，值是空闲多少秒后自己退出（格式见 CuePi README「协议」）；
 * 扩展在 hello 里带回"托管"。托管的只是这个进程：读出后存进进程内（/reload 重新载入扩展时还认得出）并从环境里删掉，
 * 否则 Agent 起的子进程（命令、里面再起的 pi）都继承它，也自认托管、空闲到点自己退出。 */
const HOSTED_ENV = "CUEPAD_HOSTED";
const HOSTED_KEY = Symbol.for("cuepad.hostedIdleSeconds");
const processScope = globalThis as { [HOSTED_KEY]?: number };
processScope[HOSTED_KEY] ??= Number(process.env[HOSTED_ENV]);
delete process.env[HOSTED_ENV];
const HOSTED_IDLE_SECONDS = processScope[HOSTED_KEY];
const IS_HOSTED = Number.isFinite(HOSTED_IDLE_SECONDS) && HOSTED_IDLE_SECONDS > 0;
/** Pi 的思考强度，由弱到强（pi-ai 的 `ModelThinkingLevel`） */
const THINKING_LEVELS: readonly ThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
/** 交给 CuePad 用来定位终端的环境变量 */
const TERMINAL_ENV_KEYS = ["TERM_PROGRAM", "__CFBundleIdentifier", "TMUX", "TMUX_PANE"];

/** 查订阅额度的单个请求最多等这么久（接口实测约 150ms；VPN 断了就是查不到，CuePad 保留上次的值） */
const QUOTA_TIMEOUT_MS = 3_000;
const FIVE_HOURS = 5 * 3_600;
const WEEK = 7 * 86_400;
/** 订阅额度：Pi 用 OAuth 订阅登录的提供方（其余是按量的 API 密钥，没有额度窗口）。查用量的接口只读、不耗额度。 */
const QUOTA_PROVIDERS: Record<string, { url: string; headers: (token: string) => Record<string, string>; parse: (body: unknown) => QuotaWindow[] }> = {
	anthropic: { url: "https://api.anthropic.com/api/oauth/usage", headers: () => ({ "anthropic-beta": "oauth-2025-04-20" }), parse: claudeUsage },
	"openai-codex": {
		url: "https://chatgpt.com/backend-api/wham/usage", headers: (token) => ({ "ChatGPT-Account-Id": codexAccount(token) }),
		parse: (body) => codexWindows(record(record(body).rate_limit), "primary_window", "secondary_window", "limit_window_seconds", 1),
	},
};

/** 一个额度窗口：长度（秒）、已用比例（0..1）、重置时刻（Unix 秒）、只算某个模型时的模型显示名；
 * `binding` 是提供方说此刻卡着的就是它（Claude 响应头的 representative-claim），提供方没说的不带 */
type QuotaWindow = { seconds: number; used: number; resetsAt: number; model: string | null; binding?: true };
/** 一个提供方的一次观测；`complete` 是全部窗口（查用量接口得到的），回复里带回的只有一部分 */
type Quota = { provider: string; windows: QuotaWindow[]; complete: boolean };

function record(value: unknown): Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function finite(value: unknown): number | null {
	const number = typeof value === "string" ? Number(value) : value;
	return typeof number === "number" && Number.isFinite(number) ? number : null;
}

function quotaWindow(seconds: number | null, used: number | null, resetsAt: number | null, model: string | null = null): QuotaWindow[] {
	return seconds !== null && seconds > 0 && used !== null && used >= 0 && resetsAt !== null ? [{ seconds, used, resetsAt, model }] : [];
}

/** Claude 响应头里的窗口：头里的名字、representative-claim 里的名字、长度。 */
const CLAUDE_HEADER_WINDOWS = [
	{ header: "5h", claim: "five_hour", seconds: FIVE_HOURS },
	{ header: "7d", claim: "seven_day", seconds: WEEK },
] as const;

/** Claude 每次回复的响应头：5 小时与本周两个窗口（比例 0..1、重置 Unix 秒），没有按模型的周额度；representative-claim 指的那个标为卡着的。
 * API 密钥的回复没有这些头。 */
function claudeHeaderWindows(headers: Record<string, string>): QuotaWindow[] {
	const header = (window: string, field: string) => finite(headers[`anthropic-ratelimit-unified-${window}-${field}`]);
	const claim = headers["anthropic-ratelimit-unified-representative-claim"];
	return CLAUDE_HEADER_WINDOWS.flatMap((w) =>
		quotaWindow(w.seconds, header(w.header, "utilization"), header(w.header, "reset"))
			.map((window): QuotaWindow => w.claim === claim ? { ...window, binding: true } : window));
}

/** Claude 的用量接口：`limits[]` 里的 5 小时、本周与按模型的周额度（百分比、ISO 时刻）。 */
function claudeUsage(body: unknown): QuotaWindow[] {
	const limits = record(body).limits;
	if (!Array.isArray(limits)) return [];
	return limits.flatMap((value) => {
		const entry = record(value);
		const percent = finite(entry.percent);
		const used = percent === null ? null : percent / 100;
		const reset = typeof entry.resets_at === "string" ? Date.parse(entry.resets_at) / 1000 : null;
		const resetsAt = reset !== null && Number.isFinite(reset) ? reset : null;
		if (entry.kind === "session") return quotaWindow(FIVE_HOURS, used, resetsAt);
		if (entry.kind === "weekly_all") return quotaWindow(WEEK, used, resetsAt);
		const model = record(record(entry.scope).model).display_name;
		if (entry.kind === "weekly_scoped" && typeof model === "string" && model) return quotaWindow(WEEK, used, resetsAt, model);
		return [];
	});
}

/** Codex 的窗口：流里的 `codex.rate_limits`（`primary`/`secondary`，长度按分钟）与用量接口（`primary_window`/`secondary_window`，长度按秒）同一形状。 */
function codexWindows(limits: Record<string, unknown>, primary: string, secondary: string, length: string, unit: number): QuotaWindow[] {
	return [limits[primary], limits[secondary]].flatMap((value) => {
		const entry = record(value);
		const span = finite(entry[length]);
		const percent = finite(entry.used_percent);
		return quotaWindow(span === null ? null : span * unit, percent === null ? null : percent / 100, finite(entry.reset_at));
	});
}

/** Codex 的令牌里带着账号 id，用量接口要它。 */
function codexAccount(token: string): string {
	const claims = record(JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8")));
	const id = record(claims["https://api.openai.com/auth"]).chatgpt_account_id;
	if (typeof id !== "string" || !id) throw new Error("codex token has no account id");
	return id;
}

/** Pi 的思考强度，包本身不导出这个类型 */
type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;
type Model = NonNullable<ExtensionContext["model"]>;
type UserContent = Parameters<ExtensionAPI["sendUserMessage"]>[0];
type DeliverAs = "steer" | "followUp";
/** CuePad 发来的一行命令：字段来自 JSON，类型没有保证，逐处校验后才用 */
type Command = Record<string, unknown>;
type DialogMethod = (...args: unknown[]) => unknown;
type Ack = (fields: object) => void;
type Reject = (error: string) => void;

function isThinkingLevel(value: unknown): value is ThinkingLevel {
	return THINKING_LEVELS.some((level) => level === value);
}

function isModelRef(value: unknown): value is { provider: string; id: string } {
	return typeof value === "object" && value !== null && "provider" in value && typeof value.provider === "string" && "id" in value && typeof value.id === "string";
}

function isImages(value: unknown): value is { mimeType: string; data: string }[] {
	return Array.isArray(value) && value.every((i) => typeof i?.mimeType === "string" && typeof i?.data === "string");
}

function isDeliverAs(value: unknown): value is DeliverAs {
	return value === "steer" || value === "followUp";
}

function reason(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

type State =
	| { kind: "idle" }
	/** 工作中、没在调工具：正在出字也算（正在说的话另走 `draft`） */
	| { kind: "thinking" }
	| { kind: "tool"; tool: string; tools: string[]; detail?: string }
	/** 自己这轮已经歇下，还有子代理在飞：仍在处理 */
	| { kind: "delegating" }
	/** 在压缩上下文：手动 /compact、上下文快满时自动压缩、上下文溢出后压缩再重试，都是它 */
	| { kind: "compacting" }
	| { kind: "waiting_user"; promptKind: string; title?: string }
	| { kind: "done"; aborted: boolean }
	| { kind: "error"; error: string };

/** 事件只更新变量，对外状态只由 derive() 推导。 */
class StateTracker {
	active = false;
	tools = new Map<string, { name: string; detail?: string }>();
	prompt: { kind: string; title?: string } | null = null;
	/** agent_end 记录结果，agent_settled 才生效：重试/压缩/排队消息都可能在 agent_end 之后继续 */
	outcome: State = { kind: "done", aborted: false };
	/** 这一轮收到过 CuePad 的停止（`abort` 命令） */
	stopped = false;
	settled: State | null = null;
	/** session_before_compact 到 session_compact / session_compact_failed */
	compacting = false;

	/** `inFlight`：在飞子代理数（FireCode 发布） */
	derive(inFlight: number): State {
		if (this.prompt) return { kind: "waiting_user", promptKind: this.prompt.kind, title: this.prompt.title };
		if (this.compacting) return { kind: "compacting" };
		if (this.active) {
			if (this.tools.size > 0) {
				const running = [...this.tools.values()];
				const latest = running[running.length - 1];
				return { kind: "tool", tool: latest.name, tools: running.map((t) => t.name), detail: latest.detail };
			}
			return { kind: "thinking" };
		}
		if (inFlight > 0) return { kind: "delegating" };
		return this.settled ?? { kind: "idle" };
	}
}

type Phase = "working" | "waiting" | "error" | "idle";

/** 粗状态：计时只在它变化时动，思考、工具、等子代理之间切换不算。 */
function phaseOf(state: State): Phase {
	switch (state.kind) {
		case "thinking": case "tool": case "delegating": case "compacting": return "working";
		case "waiting_user": return "waiting";
		case "error": return "error";
		default: return "idle";
	}
}

/** 只上报一句话摘要，不上报完整参数：命令/搜索模式取首个非空行，文件类工具取文件名，超长截断。 */
function toolDetail(args: Record<string, unknown> | undefined): string | undefined {
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
function messageText(message: object): string {
	const content = "content" in message ? message.content : undefined;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.filter((block) => block?.type === "text").map((block) => block.text).join(" ");
}

/** 助手消息到目前为止的正文：文字块按换行连接，与对话读会话文件取回答的规则一致（CuePi 的 `PiHistory`）。 */
function replyText(message: object): string {
	const content = "content" in message && Array.isArray(message.content) ? message.content : [];
	return content.filter((block) => block?.type === "text").map((block) => block.text).join("\n");
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

/** 手机上看的一个子代理：`state` 是 FireCode 名册的状态原文（running/review/done/failed/interrupted/idle），时刻是毫秒，
 * `model` 是名册里的模型原子（`provider/model`） */
type Subagent = {
	name: string;
	role: string;
	state: string;
	action: string;
	startedAt: number | null;
	settledAt: number | null;
	model: string | null;
};

/** FireCode 名册里的一项：来自另一个扩展发布的事件，字段类型没有保证 */
type Worker = Partial<Record<"name" | "role" | "state" | "action" | "startedAt" | "settledAt" | "model", unknown>>;

function subagentsOf(workers: unknown): Subagent[] {
	if (!Array.isArray(workers)) return [];
	return workers.map((worker: Worker) => ({
		name: String(worker.name),
		role: String(worker.role),
		state: String(worker.state),
		action: clip(String(worker.action ?? ""), SUBAGENT_ACTION_LIMIT) ?? "",
		startedAt: typeof worker.startedAt === "number" ? worker.startedAt : null,
		settledAt: typeof worker.settledAt === "number" ? worker.settledAt : null,
		model: typeof worker.model === "string" && worker.model ? worker.model : null,
	}));
}

/** 会话里第一条用户消息（按文件顺序，与 Pi 会话列表一致）。 */
function firstUserMessage(entries: SessionEntry[]): string | null {
	for (const entry of entries) {
		if (entry.type !== "message" || entry.message.role !== "user") continue;
		const text = messageText(entry.message);
		if (text) return preview(text);
	}
	return null;
}

/** 模型支持的思考强度，与 pi-ai 的 `getSupportedThinkingLevels` 同一规则（只读模型的公开字段，不引入对 pi-ai 的依赖）：
 * 不支持思考的只有 off，`thinkingLevelMap` 里为 null 的不支持，xhigh、max 要模型显式声明。设置时 Pi 本来就会按模型夹取，这里只决定给手机列哪些。 */
function thinkingLevels(model: Model): ThinkingLevel[] {
	if (!model.reasoning) return ["off"];
	return THINKING_LEVELS.filter((level) => {
		const mapped = model.thinkingLevelMap?.[level];
		if (mapped === null) return false;
		return level === "xhigh" || level === "max" ? mapped !== undefined : true;
	});
}

function describeModel(model: Model) {
	return { provider: model.provider, id: model.id, name: model.name ?? model.id, thinking: thinkingLevels(model), images: model.input.includes("image") };
}

function readTTY(): Promise<string | null> {
	return new Promise((resolve) => {
		execFile("ps", ["-o", "tty=", "-p", String(process.pid)], { encoding: "utf8" }, (error, stdout) => {
			const tty = error ? "" : stdout.trim();
			resolve(tty && tty !== "??" ? tty : null);
		});
	});
}


/** 会话名（`/name`）与首条用户消息：CuePad 据此按 Pi 会话列表的规则显示会话；其余是近况 */
type Info = {
	name: string | null; firstMessage: string | null; question: Question | null;
	subagents: Subagent[];
	/** 当前模型、思考强度与可换的模型（Pi 里已配好密钥的）：手机据此选 */
	model: ReturnType<typeof describeModel> | null; thinking: ThinkingLevel | null; models: ReturnType<typeof describeModel>[];
	/** 上下文余量：已用 token（压缩后到下一次回答前未知，为 null）与当前模型的窗口；没有模型为 null */
	context: { tokens: number | null; window: number } | null;
	/** 此刻能用的斜杠命令：能执行的内置命令 + 扩展命令 + 提示词模板 + skill */
	commands: CommandInfo[];
};
type CommandInfo = { name: string; description: string | null; source: "builtin" | "extension" | "prompt" | "skill"; hint: string | null };
/** 等你回答的弹窗：`id` 非空的可以从 CuePad 作答（confirm/select/text）；editor 与 custom 只能在 Pi 里答 */
type Question = { id: string | null; kind: string; text: string; options: string[] };

/** 此刻可选的模型：与 Pi 的 /model 一致——配了范围（`--models`、`enabledModels`）就是范围内的，否则是已配好密钥的全部；当前模型总在其中。 */
function modelChoices(ctx: ExtensionContext): Model[] {
	const scoped = (ctx.scopedModels ?? []).map((entry) => entry.model);
	const choices = scoped.length > 0 ? scoped : ctx.modelRegistry.getAvailable();
	const current = ctx.model;
	return current && !choices.some((m) => m.provider === current.provider && m.id === current.id) ? [...choices, current] : choices;
}

/** 此刻的模型配置；Pi 里换了模型、强度后重新取。 */
function modelInfo(pi: ExtensionAPI, ctx: ExtensionContext): Pick<Info, "model" | "thinking" | "models"> {
	const current = ctx.model;
	return {
		model: current ? describeModel(current) : null,
		thinking: current ? pi.getThinkingLevel() : null,
		models: modelChoices(ctx).map(describeModel),
	};
}

/** 上下文余量：Pi 估算的已用 token 与当前模型的窗口（压缩后到下一次回答前 tokens 为 null）。 */
function contextInfo(ctx: ExtensionContext): Pick<Info, "context"> {
	const usage = ctx.getContextUsage();
	return { context: usage ? { tokens: usage.tokens, window: usage.contextWindow } : null };
}

/** 此刻的命令清单。扩展命令与内置同名时内置先匹配（与 Pi 的终端一致），同名的扩展命令用不到，不列。 */
function commandInfo(pi: ExtensionAPI): Pick<Info, "commands"> {
	const builtin: CommandInfo[] = BUILTIN_COMMANDS.map((c) => ({
		name: c.name, description: c.description, source: "builtin", hint: "hint" in c ? c.hint : null,
	}));
	const taken = new Set<string>([INTERNAL_COMMAND, ...BUILTIN_COMMANDS.map((c) => c.name)]);
	const resources: CommandInfo[] = pi.getCommands().filter((c) => !taken.has(c.name)).map((c) => ({
		name: c.name, description: clip(String(c.description ?? "").replace(/\s+/g, " "), COMMAND_DESCRIPTION_LIMIT), source: c.source, hint: null,
	}));
	return { commands: [...builtin, ...resources] };
}

/** `provider/id` 精确匹配，或模型 id 在可选模型里唯一（与 Pi 的 /model 同一份候选）。 */
function findModel(ctx: ExtensionContext, reference: string): Model | undefined {
	const models = modelChoices(ctx);
	const slash = reference.indexOf("/");
	const exact = slash > 0 ? models.find((m) => m.provider === reference.slice(0, slash) && m.id === reference.slice(slash + 1)) : undefined;
	if (exact) return exact;
	const byId = models.filter((m) => m.id === reference);
	return byId.length === 1 ? byId[0] : undefined;
}

export default function (pi: ExtensionAPI) {
	const socketDirectory = process.env.CUEPAD_PI_SOCKET_DIR ?? `/tmp/cuepad-${process.getuid!()}`;
	/** 只属于这个进程里的第一个会话：读走后清掉，之后 /new 开的会话不带 */
	let launchToken: string | null = process.env[LAUNCH_TOKEN_ENV] || null;
	delete process.env[LAUNCH_TOKEN_ENV];
	/** FireCode 在本扩展实例的事件总线上发布的最新事实。总线随扩展实例走，FireCode 的发布与本扩展的 session_start 先后不定，
	 * 所以记在实例上，由服务中的会话读取 */
	const firecode = { inFlight: 0, subagents: [] as Subagent[] };
	/**
	 * 本扩展实例此刻服务的会话，只在终端与 RPC 会话里有：session_start 建、session_shutdown 整体拆掉（连同它挂的全部事件处理）。
	 * print/json 是没有输入框的运行——一次性的 pi -p，或其他扩展在同进程里开的子会话（FireCode 子代理）——这里没有它：不作为会话出现，
	 * 也不碰进程级的事（托管进程的空闲自退、退出钩子）。否则子会话一歇下就给整个进程挂上空闲自退，
	 * 指挥官与别的子代理还在做事也会被一起结束（被中止那一轮的 agent_settled 还会晚于 session_shutdown 到来，挂上的计时没人再清）。
	 */
	let live: ReturnType<typeof serve> | undefined;

	pi.events?.on(FIRECODE_WORKERS_CHANNEL, (data) => {
		const { inFlight } = (data ?? {}) as { inFlight?: unknown };
		firecode.inFlight = typeof inFlight === "number" ? inFlight : 0;
		live?.commit();
	});
	pi.events?.on(FIRECODE_SUBAGENTS_CHANNEL, (data) => {
		firecode.subagents = subagentsOf((data as { workers?: unknown } | null)?.workers);
		live?.updateInfo({ subagents: firecode.subagents });
	});

	pi.registerCommand(INTERNAL_COMMAND, {
		description: "CuePad 内部使用：需要命令上下文的会话操作（重新载入会话文件、新会话、重载、克隆）",
		handler: async (action, command: ExtensionCommandContext) => {
			switch (action.trim()) {
				case "reload-session": {
					const file = command.sessionManager.getSessionFile();
					if (file) await command.switchSession(file);
					break;
				}
				case "new": await command.newSession(); break;
				case "reload-if-idle": await live?.reloadIfIdle(command); break;
				case "reload": await command.reload(); break;
				case "clone": {
					const leaf = command.sessionManager.getLeafId();
					if (leaf) await command.fork(leaf, { position: "at" });
					break;
				}
			}
		},
	});

	pi.on("session_start", (_event, ctx) => {
		if (process.env[PROBE_ENV]) {
			// 没有配好密钥的模型（没登录）时 Pi 仍给出一个占位的当前模型，报成没有模型
			const { model, models } = ctx.modelRegistry.getAvailable().length > 0 ? modelInfo(pi, ctx) : { model: null, models: [] };
			fs.writeSync(1, JSON.stringify({ cuepadProbe: { model, models } }) + "\n");
			return;
		}
		if (ctx.mode !== "tui" && ctx.mode !== "rpc") return;
		live = serve(ctx, launchToken);
		launchToken = null;
	});
	pi.on("session_shutdown", (event) => {
		live?.close(event.reason);
		live = undefined;
	});

	/** 服务一个终端或 RPC 会话：开 socket、跟踪状态、托管时空闲自退；返回会话外要用的几样。 */
	function serve(ctx: ExtensionContext, launchToken: string | null) {
		const tracker = new StateTracker();
		const clients = new Set<net.Socket>();
		const state = () => tracker.derive(firecode.inFlight);
		const initial = state();
		/** 主会话最后一次模型回合开始的时间（`turn_start` 的时刻）：早于这一回合写进会话文件的回答，CuePad 据此认出歇下时这一轮的回答读到没有。
		 * 取每个回合而不取 agent_start：一次运行里接着处理排队的话，最后的回答出自最后一个回合 */
		let turnSince: number | null = null;
		let lastKey = JSON.stringify([initial, turnSince]);
		let phase: Phase = phaseOf(initial);
		/** 进入当前粗状态的时间 */
		let since = Date.now();
		/** 这段连续处理（离开空闲到彻底歇下，中间等你确认也算）开始的时间；空闲、出错时为 null */
		let busySince: number | null = phase === "working" ? since : null;
		let server: net.Server | undefined;
		/** 删掉本会话的 socket 文件；也挂在进程退出上（进程被 SIGTERM 之外的方式结束时，Pi 不发 session_shutdown） */
		let removeSocket: (() => void) | undefined;
		const tty = readTTY();
		/** 会话载入时的条目数：之后多出来的是这个进程自己写的 */
		const loadedEntries = ctx.sessionManager.getEntries().length;
		let info: Info = {
			name: pi.getSessionName() ?? null,
			firstMessage: firstUserMessage(ctx.sessionManager.getEntries()),
			question: null,
			subagents: firecode.subagents,
			...modelInfo(pi, ctx),
			...contextInfo(ctx),
			...commandInfo(pi),
		};
		/** CuePad 送进来、还没落成会话里一条消息的投送请求：文字 → 请求 id，按发出的先后（同一文字发了两次时先发的先认领）。
		 * 进程退出时还在这里的（排在 Pi 队列里、留着的）随进程丢掉，告别里报没送到（`bye.undelivered`） */
		const deliveries: { text: string; id: string }[] = [];
		/** 正在弹出的对话框（最外层）。ui_prompt_start 只带标题，说明与选项要在调用时记下；`settle` 从 CuePad 作答 */
		let asking: (Question & { settle?: (value: unknown) => void; dismiss?: () => void }) | null = null;

		const write = (socket: net.Socket, message: object) => {
			if (!socket.destroyed) socket.write(JSON.stringify(message) + "\n");
		};

		/** 压缩开始时的粗状态与计时：压缩完（或失败、取消）回到同一个粗状态时，计时也回到那时的起点——
		 * 歇着时的手动压缩不是新的一轮，压完还是原来那次"做完了"，CuePad 不因此提示、也不算有新回复。 */
		let beforeCompaction: { phase: Phase; since: number; busySince: number | null } | null = null;
		/** 手动压缩期间 Pi 拒收新消息（"Cannot submit a prompt while compaction is in progress"），而扩展的 sendUserMessage
		 * 不回报错误、话会悄悄丢掉：这期间 CuePad 送来的话先留着，压缩结束再按到达顺序交给 Pi；压完之前会话就关掉（退出、重新载入、
		 * 换会话）时，告别里报出它们的投送请求 id（`bye.undelivered`），CuePad 记为没送到。自动压缩期间 Pi 照常排队，不经这里。 */
		let manualCompaction = false;
		const held: { deliveryId?: string; deliver: () => void }[] = [];

		/**
		 * 正在说的话（`draft`）：主会话当前这条助手消息到目前为止的正文，给 CuePad 逐字显示；思考与工具参数不算，FireCode 的子代理是别的会话、不经这里。
		 * 增量合并到每 `DRAFT_INTERVAL_MS` 一次，这条说完时立即补发全文；它转成工具调用、被停下或出错、下一条助手消息开始时清掉（`text: null`）。
		 * 正常说完的不清：CuePad 在对话（读会话文件）里出现这一条后自己换下。`since` 是这条开始出字的时刻。
		 */
		let draft: { text: string; since: number } | null = null;
		/** 这条消息已转成工具调用：之后的正文不再算草稿 */
		let draftClosed = false;
		let draftSentAt = 0;
		let draftTimer: ReturnType<typeof setTimeout> | undefined;

		function sendDraft() {
			clearTimeout(draftTimer);
			draftTimer = undefined;
			draftSentAt = Date.now();
			const message = { t: "draft", text: draft?.text ?? null, since: draft?.since ?? null };
			for (const client of clients) write(client, message);
		}

		/** `now`：这条说完了，不等合并的间隔 */
		function growDraft(message: object, now = false) {
			const text = replyText(message);
			if (draftClosed || !text || text === draft?.text) {
				if (now && draftTimer) sendDraft();
				return;
			}
			draft = { text, since: draft?.since ?? Date.now() };
			if (now) return sendDraft();
			if (draftTimer) return;
			const wait = draftSentAt + DRAFT_INTERVAL_MS - Date.now();
			if (wait <= 0) sendDraft();
			else draftTimer = setTimeout(sendDraft, wait);
		}

		function clearDraft() {
			if (!draft) return;
			draft = null;
			sendDraft();
		}

		/** 状态没变就不发；没有客户端时只维护状态与计时，不做任何 I/O。 */
		function commit(resume?: { phase: Phase; since: number; busySince: number | null }) {
			const current = state();
			const key = JSON.stringify([current, turnSince]);
			if (key === lastKey) return;
			lastKey = key;
			const next = phaseOf(current);
			if (next !== phase) {
				const now = Date.now();
				since = resume?.phase === next ? resume.since : now;
				busySince = resume?.phase === next ? resume.busySince : next === "working" || next === "waiting" ? busySince ?? now : null;
				phase = next;
				scheduleIdleExit();
				reloadWhenIdle();
			}
			if (clients.size === 0) return;
			const message = { t: "state", state: { ...current, since, busySince, turnSince } };
			for (const client of clients) write(client, message);
		}

		/**
		 * 托管的进程空闲（这一轮做完、没有等你确认、子代理也歇下）满时限就自己退出：会话文件都在，CuePad 下次发话再恢复。
		 * 进程不靠 CuePad 活着（App 退出、更新、崩溃都不影响它），所以计时也在这里。退出走给自己发 SIGTERM——Pi 对它的处理就是
		 * 优雅收尾（清理后台子进程、发 session_shutdown，本扩展随之告别、删 socket）。否决 `ctx.shutdown()`：RPC 模式只在这一轮歇下
		 * 或从标准输入读到下一条命令后才检查退出请求，托管进程空闲时两者都不会再发生，请求永远不生效。
		 */
		let idleExit: ReturnType<typeof setTimeout> | undefined;
		function scheduleIdleExit() {
			if (!IS_HOSTED) return;
			if (phase === "working" || phase === "waiting") {
				clearTimeout(idleExit);
				idleExit = undefined;
			} else {
				idleExit ??= setTimeout(() => process.kill(process.pid, "SIGTERM"), HOSTED_IDLE_SECONDS * 1000);
			}
		}

		/**
		 * 自己重新载入：磁盘上的本文件换成了别的版本（CuePad 升级时写临时文件再改名，所以盯所在目录，不盯文件本身；事件驱动，不轮询），
		 * 就等到空闲（这一轮做完、没有等你回答的弹窗、子代理都歇下、不在压缩）经内部命令调 `ctx.reload()`：它清掉 Pi 的扩展缓存、
		 * 从磁盘载入新版本，新实例以新协议重新连上 CuePad，用户不用自己 /reload；在跑的一轮不打断，歇下时（`commit` 里进入空闲）再重载。
		 * 否决重新载入会话（`switchSession`）：同一工作目录下 Pi 复用缓存里的旧模块，载入的还是旧代码。
		 */
		let ownWatcher: fs.FSWatcher | undefined;
		let newerOnDisk = false;
		let ownReload: ReturnType<typeof setImmediate> | undefined;
		function watchOwnFile() {
			ownWatcher = fs.watch(path.dirname(OWN_FILE), (_event, name) => {
				if (name !== null && name !== path.basename(OWN_FILE)) return;
				let source: string;
				try { source = fs.readFileSync(OWN_FILE, "utf8"); }
				catch (error) {
					newerOnDisk = false;
					if ((error as NodeJS.ErrnoException).code !== "ENOENT") ctx.ui.notify(`CuePad 扩展升级检查失败：${reason(error)}`, "error");
					return;
				}
				const version = Number(/const EXTENSION_VERSION = (\d+);/.exec(source)?.[1]);
				newerOnDisk = Number.isInteger(version) && version !== EXTENSION_VERSION;
				reloadWhenIdle();
			});
			ownWatcher.on("error", (error) => ctx.ui.notify(`CuePad 扩展文件监听失败：${reason(error)}`, "error"));
		}
		function canReload() {
			return (phase === "idle" || phase === "error") && !asking;
		}
		function reloadWhenIdle() {
			if (!newerOnDisk || ownReload || !canReload()) return;
			ownReload = runInternal("reload-if-idle");
		}
		/** 内部命令 `reload-if-idle` 里：再核对一次空闲后从磁盘载入新版本。 */
		async function reloadIfIdle(command: ExtensionCommandContext) {
			if (!newerOnDisk || !canReload()) {
				ownReload = undefined;
				return;
			}
			// session_compact 先通知扩展、再收起 Pi 的压缩标记：用它的空闲 Promise 等收尾，不轮询
			await command.waitForIdle();
			ownReload = undefined;
			if (!newerOnDisk || !canReload() || !command.isIdle()) return;
			newerOnDisk = false;
			await command.reload();
		}

		/** 变了的项才发，而且只发变了的那几项：模型表（几百个）与命令清单很大，上下文用量每轮都变，不能每次带上整份。
		 * 没出现的键表示不变，null 是新值；hello 带全部。 */
		function updateInfo(changes: Partial<Info>) {
			const changed: Partial<Info> = {};
			for (const key of Object.keys(changes) as (keyof Info)[]) {
				if (JSON.stringify(changes[key]) !== JSON.stringify(info[key])) Object.assign(changed, { [key]: changes[key] });
			}
			if (Object.keys(changed).length === 0) return;
			info = { ...info, ...changed };
			for (const client of clients) write(client, { t: "info", ...changed });
		}

		/** 正在查的额度：几个客户端同时要时共用这一次 */
		let quotaFetch: Promise<string[]> | null = null;

		/** 额度不属于会话、属于账号：每次观测都发给所有客户端（一行，随每次回复），由 CuePad 记到账号上。
		 * 不在这里去重：值没变的观测也说明刚观测过，"更新于"要跟上；写不写库只由 CuePad 定（`CueStore.recordQuota`）。 */
		function reportQuota(quota: Quota) {
			if (clients.size === 0 || quota.windows.length === 0) return;
			for (const client of clients) write(client, { t: "quota", ...quota });
		}

		/** 查一个提供方的用量：没用 OAuth 订阅登录的（API 密钥、没登录）跳过，返回 false；查到就报出去。令牌经 Pi 取（会自动刷新）。 */
		async function fetchQuota(provider: string): Promise<boolean> {
			const source = QUOTA_PROVIDERS[provider];
			const registry = ctx.modelRegistry;
			const model = registry.getAll().find((m) => m.provider === provider);
			if (!model || !registry.isUsingOAuth(model)) return false;
			const token = (await registry.getProviderAuth(provider))?.auth.apiKey;
			if (!token) throw new Error(`${provider}: no token`);
			const response = await fetch(source.url, {
				headers: { Authorization: `Bearer ${token}`, Accept: "application/json", ...source.headers(token) },
				signal: AbortSignal.timeout(QUOTA_TIMEOUT_MS),
			});
			if (!response.ok) throw new Error(`${provider}: HTTP ${response.status}`);
			const windows = source.parse(await response.json());
			if (windows.length === 0) throw new Error(`${provider}: unrecognized usage format`);
			reportQuota({ provider, windows, complete: true });
			return true;
		}

		/** 查一次所有订阅的额度；全部查到（或没有订阅）才 ok，否则带上各家的失败原因。查到的那几家已经报出去了。 */
		function handleQuota(ack: Ack, reject: Reject) {
			quotaFetch ??= Promise.allSettled(Object.keys(QUOTA_PROVIDERS).map(fetchQuota))
				.then((results) => results.flatMap((r) => r.status === "rejected" ? [reason(r.reason)] : []))
				.finally(() => { quotaFetch = null; });
			void quotaFetch.then((failures) => failures.length === 0 ? ack({ ok: true }) : reject(`failed: ${failures.join("; ")}`));
		}

		/** 上下文用量随每一轮、压缩、换模型、换分支变化。 */
		function refreshContext() {
			updateInfo(contextInfo(ctx));
		}

		/** 命令清单只会在会话载入（`session_start`，含重载）和资源扩展后变——扩展注册的命令、提示词模板、skill；后者发生在 `session_start`
		 * 之后且没有事件，所以每次提交消息前（`before_agent_start`）取一次，而不是每一轮（`turn_end`）。 */
		function refreshCommands() {
			updateInfo(commandInfo(pi));
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
				state: { ...state(), since, busySince, turnSince },
				launchToken,
				hosted: IS_HOSTED,
				...info,
			};
		}

		// ---- CuePad → 扩展 ----
		function handleCommand(socket: net.Socket, command: Command | null) {
			const ack: Ack = (fields) => write(socket, { t: "ack", id: command?.id ?? null, ...fields });
			const reject: Reject = (error) => ack({ ok: false, error });
			try {
				if (command?.t === "send") return handleSend(command, ack, reject);
				if (command?.t === "command") return void handleSlash(command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
				if (command?.t === "answer") return handleAnswer(command, ack, reject);
				if (command?.t === "reload") return handleReload(ack);
				if (command?.t === "end") return handleEnd(ack);
				if (command?.t === "abort") return handleAbort(ack);
				if (command?.t === "config") return void handleConfig(command, ack, reject).catch((error) => reject(`failed: ${reason(error)}`));
				if (command?.t === "quota") return handleQuota(ack, reject);
				reject("bad_request");
			} catch (error) {
				reject(`failed: ${reason(error)}`);
			}
		}

		function handleSend(command: Command, ack: Ack, reject: Reject) {
			const images = command.images ?? [];
			const text = command.text ?? "";
			const deliverAs = command.deliverAs ?? "followUp";
			if (typeof text !== "string" || !isImages(images) || !isDeliverAs(deliverAs)) return reject("bad_request");
			if (text.length === 0 && images.length === 0) return reject("empty");

			const content: UserContent = images.length === 0
				? text
				: [{ type: "text", text }, ...images.map((i) => ({ type: "image" as const, data: i.data, mimeType: i.mimeType }))];
			const busy = !ctx.isIdle();
			const deliveryId = typeof command.deliveryId === "string" ? command.deliveryId : undefined;
			if (deliveryId) deliveries.push({ text, id: deliveryId });
			// deliverAs 只在会话正忙时生效；总是带上，避免"检查空闲"与"发送"之间 agent 恰好开始而抛错
			const deliver = () => pi.sendUserMessage(content, { deliverAs });
			if (manualCompaction) held.push({ deliveryId, deliver });
			else deliver();
			ack({ ok: true, delivered: busy ? deliverAs : "immediate" });
		}

		/**
		 * CuePad 在后台托管的同一会话刚做完一轮、让出退出：那一轮写进会话文件的内容，这个进程（用户打开时已载入）看不到。
		 * 这个进程从载入起没写过，就把会话从文件重新载入到最新——之后说的话接在那一轮后面，不分支；写过了（会话已分出支线）
		 * 就不动，提示一句。Pi 只在命令里给切换会话的能力（`switchSession`），所以经 `sendUserMessage` 触发本扩展的命令。
		 */
		function handleReload(ack: Ack) {
			const file = ctx.sessionManager.getSessionFile();
			const inMemory = ctx.sessionManager.getEntries().length;
			if (!file || entriesOnDisk(file) <= inMemory) return ack({ ok: true, reloaded: false });
			if (inMemory !== loadedEntries || !ctx.isIdle()) {
				ctx.ui.notify("CuePad 在后台跑的那一轮在你打开会话后才写完，会话分出了支线；用 /tree 查看", "warning");
				return ack({ ok: true, reloaded: false });
			}
			ack({ ok: true, reloaded: true });
			runInternal("reload-session");
		}

		/** 下一轮事件循环再触发：重载、新会话会拆掉本扩展实例并关掉连接，`ack` 要先写出去。会话正忙时按 followUp 排队（Pi 1.2 起不给就抛错）。 */
		function runInternal(action: string) {
			return later("会话操作", () => pi.sendUserMessage(`/${INTERNAL_COMMAND} ${action}`, { deliverAs: "followUp", expandPromptTemplates: true }));
		}

		/** 下一轮事件循环再交给 Pi（返回排好的这一次，可撤）。`sendUserMessage` 不返回结果：异步的失败 Pi 报在它自己的界面里；同步抛出的（本扩展实例已被换掉等）
		 * 在这里报，不让它在事件循环里成为未捕获的异常。 */
		function later(what: string, action: () => void) {
			return setImmediate(() => {
				try {
					action();
				} catch (error) {
					ctx.ui.notify(`CuePad：${what}没交给 Pi：${reason(error)}`, "error");
				}
			});
		}

		/**
		 * 斜杠命令：内置的（能在非 TUI 下执行的）由本扩展调 Pi 的接口做，其余（扩展命令、提示词模板、skill）经
		 * `sendUserMessage(…, { expandPromptTemplates: true })` 交给 Pi 派发——扩展命令执行（会话正忙也立即执行）、模板与 skill 展开成这一轮的提示词；
		 * 不带这个选项的 `sendUserMessage` 只把它当普通文字。清单里没有的名字拒绝，不当文字发出去。
		 * `ack` 表示已受理：扩展命令的执行结果与报错只出现在 Pi 自己的界面（`ctx.ui`），这里看不到。
		 */
		async function handleSlash(command: Command, ack: Ack, reject: Reject) {
			const text = command.text;
			const deliverAs = command.deliverAs ?? "followUp";
			if (typeof text !== "string" || !text.startsWith("/") || !isDeliverAs(deliverAs)) return reject("bad_request");
			const space = text.search(/\s/);
			const name = text.slice(1, space < 0 ? undefined : space);
			const args = space < 0 ? "" : text.slice(space + 1).trim();
			const builtin = BUILTIN_COMMANDS.find((c) => c.name === name);
			if (builtin) {
				const error = await runBuiltin(builtin, args);
				return error ? reject(error) : ack({ ok: true });
			}
			if (name === INTERNAL_COMMAND || !pi.getCommands().some((c) => c.name === name)) return reject("unknown_command");
			// 命令没有投送请求 id，留着的话会话关掉时报不出来：手动压缩期间直接拒收，CuePad 照常显示没发出去
			if (manualCompaction) return reject("compacting");
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
					runInternal("clone");
					return;
				case "new":
				case "reload":
					runInternal(builtin.name);
					return;
			}
			updateInfo({ ...modelInfo(pi, ctx), ...contextInfo(ctx) });
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

		/**
		 * 结束会话：与用户在 Pi 里退出同一条路（`ctx.shutdown`——TUI 恢复终端并提示怎么恢复会话，退出时发 `bye quit`）。
		 * 正在跑的一轮先中止、等你回答的弹窗先取消，否则 Pi 要等它们结束才会退出。RPC 模式只在读到下一条命令或这一轮结束时检查退出请求，
		 * 所以后台托管的进程不走这里，由 CuePad 给它发 SIGTERM（`PiBridge.end`）。
		 */
		function handleEnd(ack: Ack) {
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
		function handleAbort(ack: Ack) {
			asking?.dismiss?.();
			if (!ctx.isIdle()) {
				tracker.stopped = true;
				ctx.abort();
			}
			ack({ ok: true });
		}

		/** 会话设置：会话名（Pi 设置会话名的接口，同 `/name`）、模型、思考强度——先换模型（需要该提供方已配好密钥）再设强度，强度由 Pi 按新模型支持的范围夹取。 */
		async function handleConfig(command: Command, ack: Ack, reject: Reject) {
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
			updateInfo(modelInfo(pi, ctx));
			ack({ ok: true });
		}

		/** 回答当前弹窗：标识必须是正在等的那个（答过或换了弹窗就拒绝），答案的类型与选项要对得上。 */
		function handleAnswer(command: Command, ack: Ack, reject: Reject) {
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
					let command: Command | null;
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
			ensureSecureDirectory(socketDirectory);
			const file = path.join(socketDirectory, `${ctx.sessionManager.getSessionId()}.${process.pid}.sock`);
			if (Buffer.byteLength(file) >= SUN_PATH_LIMIT) throw new Error(`socket path too long: ${file}`);
			fs.rmSync(file, { force: true });
			server = net.createServer((socket) => void onConnection(socket));
			server.on("error", () => {});
			// chmod 既收紧权限，也会产生 FSEvents 能看到的属性变更（仅 bind 的 socket 创建事件不会被报告）
			server.listen(file, () => fs.chmodSync(file, 0o600));
			removeSocket = () => fs.rmSync(file, { force: true });
			process.on("exit", removeSocket);
		}

		function stop(reason: string) {
			// 没被读到的话随之没了，报给 CuePad，不让它们在那边一直显示成已送达：总有留着还没交给 Pi 的；
			// 进程退出时另有已交给 Pi、排在它队列里没被读到的（还没在 message_end 里认领）——Pi 的队列随进程丢掉
			const kept = held.splice(0).flatMap((h) => h.deliveryId ? [h.deliveryId] : []);
			const undelivered = reason === "quit" ? deliveries.splice(0).map((d) => d.id) : kept;
			for (const client of clients) {
				write(client, { t: "bye", reason, undelivered });
				client.end();
			}
			clients.clear();
			server?.close();
			if (removeSocket) {
				process.off("exit", removeSocket);
				removeSocket();
			}
		}

		/** 包装所有扩展共用的 ui 对象上的对话框方法（Pi 每次绑定界面都换新对象，session_start 前绑定）：记下文案与选项，
		 * 并给弹窗接上一个由我们控制的 AbortSignal。从 CuePad 作答时先记下答案再 abort：Pi 的界面随之收起
		 * （TUI 隐藏选择器，RPC 删掉待答请求），原调用按"取消"结束，包装把它换成我们的答案交回调用方。 */
		function captureDialogs(context: ExtensionUIContext) {
			const ui = context as unknown as Record<string, DialogMethod | undefined> & { [CAPTURED]?: true };
			if (ui[CAPTURED]) return;
			ui[CAPTURED] = true;
			/** `optionsAt`：对话框选项参数（含 signal）的位置；没有的（editor）不能从外面收起，只记文案 */
			const wrap = (method: string, kind: string, optionsAt: number | null, describe: (args: unknown[]) => { lines: unknown[]; options?: unknown }) => {
				const original = ui[method];
				if (typeof original !== "function") return;
				ui[method] = (...args) => {
					// 嵌套弹窗只算最外层，与 ui_prompt_start 一致
					if (asking) return original.apply(ui, args);
					const { lines, options } = describe(args);
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
					const callerOptions = args[optionsAt] as ExtensionUIDialogOptions | undefined;
					const caller = callerOptions?.signal;
					let answer: { value: unknown } | undefined;
					asking = { ...question, settle: (value) => { answer = { value }; own.abort(); }, dismiss: () => own.abort() };
					const call = [...args];
					call[optionsAt] = { ...callerOptions, signal: caller ? AbortSignal.any([caller, own.signal]) : own.signal };
					return Promise.resolve(original.apply(ui, call)).then((value: unknown) => (answer ? answer.value : value));
				};
			};
			wrap("select", "select", 2, ([title, options]) => ({ lines: [title], options }));
			wrap("confirm", "confirm", 2, ([title, message]) => ({ lines: [title, message] }));
			wrap("input", "text", 2, ([title]) => ({ lines: [title] }));
			wrap("editor", "editor", null, ([title]) => ({ lines: [title] }));
		}

		// 压缩前就失败（没有可压缩的内容、没有模型）时只有 session_compact_failed，那时什么都没变
		function finishCompaction() {
			if (!tracker.compacting) return;
			const resume = beforeCompaction ?? undefined;
			beforeCompaction = null;
			manualCompaction = false;
			tracker.compacting = false;
			commit(resume);
			// session_compact 在 Pi 收起手动压缩的标记之前发出：下一轮事件循环再交，免得又被拒收
			for (const { deliver } of held.splice(0)) later("留着的话", deliver);
		}

		const unsubscribe = [
			pi.on("model_select", () => { updateInfo(modelInfo(pi, ctx)); refreshContext(); }),
			pi.on("thinking_level_select", () => updateInfo({ thinking: ctx.model ? pi.getThinkingLevel() : null })),
			pi.on("before_agent_start", refreshCommands),
			pi.on("turn_end", refreshContext),
			pi.on("agent_settled", refreshContext),
			pi.on("session_compact", refreshContext),
			pi.on("session_tree", refreshContext),
			pi.on("session_info_changed", (event) => updateInfo({ name: event.name ?? null })),
			pi.on("message_start", (event) => {
				if (event.message.role !== "assistant") return;
				draftClosed = false;
				// 同一次运行里的下一条（排队的话接着开的一轮）：上一条已经说完落库，不再是此刻在说的
				clearDraft();
			}),
			pi.on("message_end", (event) => {
				if (event.message.role === "assistant") {
					const stop = event.message.stopReason;
					return stop === "toolUse" || stop === "aborted" || stop === "error" ? clearDraft() : growDraft(event.message, true);
				}
				if (event.message.role !== "user") return;
				// 首条消息与 Pi 会话列表一致，不区分机器消息
				updateInfo({ firstMessage: info.firstMessage ?? preview(messageText(event.message)) });
				// CuePad 送进来的：把投送请求 id 写到这条消息上。扩展先收到 message_end、Pi 再把同一个消息对象写进会话文件，
				// 所以 id 随消息落盘，对话（读会话文件）据此认出它
				const index = deliveries.findIndex((d) => d.text === messageText(event.message));
				if (index >= 0) Object.assign(event.message, { cuepadDelivery: deliveries.splice(index, 1)[0].id });
			}),

			// ---- Pi 事件 → 状态 ----
			// 提交了一条消息（你的提问，或扩展投进来的，如 FireCode 交回子代理结果）：这一轮从这里开始算。
			// FireCode 交回结果时，在飞数在这之后、agent_start 之前就归零了，从这里接上，连续处理才不会在交接处断开
			pi.on("input", () => {
				if (tracker.active) return;
				tracker.active = true;
				commit();
			}),
			pi.on("agent_start", () => {
				tracker.active = true;
				tracker.settled = null;
				tracker.outcome = { kind: "done", aborted: false };
				tracker.stopped = false;
				commit();
				clearDraft();
			}),
			pi.on("turn_start", (event) => {
				turnSince = event.timestamp;
				commit();
			}),
			pi.on("message_update", (event) => {
				const type = event.assistantMessageEvent.type;
				if (type === "text_delta") growDraft(event.message);
				if (type !== "toolcall_start") return;
				draftClosed = true;
				clearDraft();
			}),
			pi.on("tool_execution_start", (event) => { tracker.tools.set(event.toolCallId, { name: event.toolName, detail: toolDetail(event.args) }); commit(); }),
			pi.on("tool_execution_end", (event) => { tracker.tools.delete(event.toolCallId); commit(); }),
			pi.on("ui_prompt_start", (event) => {
				tracker.prompt = { kind: event.kind, title: event.title };
				const question = asking ?? { id: null, kind: event.kind, text: event.title ?? "", options: [] };
				updateInfo({ question: { id: question.id, kind: question.kind, text: clip(question.text, QUESTION_LIMIT) ?? "", options: question.options } });
				commit();
			}),
			pi.on("ui_prompt_end", () => {
				tracker.prompt = null;
				asking = null;
				updateInfo({ question: null });
				commit();
			}),
			pi.on("session_before_compact", (event) => {
				beforeCompaction = { phase, since, busySince };
				manualCompaction = event.reason === "manual";
				tracker.compacting = true;
				commit();
			}),
			pi.on("session_compact", finishCompaction),
			pi.on("session_compact_failed", finishCompaction),
			// 被停下的一轮有时以 error 结束（Pi 1.2 在工具被中止后再请求模型、请求因中止失败时记成 error）：只认确定的事实——
			// 这一轮收到过停止、或这一轮的中止信号已触发——按被停下报，不看错误文案
			pi.on("agent_end", (event, context) => {
				const last = event.messages.findLast((m) => m.role === "assistant");
				const stopped = tracker.stopped || context.signal?.aborted === true;
				if (last?.stopReason === "aborted" || (last?.stopReason === "error" && stopped)) tracker.outcome = { kind: "done", aborted: true };
				else if (last?.stopReason === "error") tracker.outcome = { kind: "error", error: last.errorMessage ?? "unknown" };
			}),
			// 订阅额度随每次回复带回来（零额外请求）：Claude 在响应头里，Codex 在流里的 codex.rate_limits 事件里
			pi.on("after_provider_response", (event, context) => {
				const provider = context.model?.provider;
				if (provider === "anthropic") reportQuota({ provider, windows: claudeHeaderWindows(event.headers), complete: false });
			}),
			pi.on("provider_stream_event", (event) => {
				const data = record(event.data);
				if (event.provider !== "openai-codex" || data.type !== "codex.rate_limits") return;
				reportQuota({ provider: event.provider, windows: codexWindows(record(data.rate_limits), "primary", "secondary", "window_minutes", 60), complete: true });
			}),
			pi.on("agent_settled", () => {
				tracker.active = false;
				tracker.tools.clear();
				tracker.settled = tracker.outcome;
				commit();
			}),
		];

		scheduleIdleExit();
		watchOwnFile();
		captureDialogs(ctx.ui);
		try {
			start();
		} catch (error) {
			ctx.ui.notify(`CuePad bridge disabled: ${reason(error)}`, "warning");
		}

		/** 会话关闭：拆掉它挂的一切——事件处理、计时、文件监听、连接与 socket。 */
		function close(why: string) {
			for (const off of unsubscribe) off();
			clearTimeout(idleExit);
			ownWatcher?.close();
			clearImmediate(ownReload);
			clearTimeout(draftTimer);
			stop(why);
		}

		return { commit, updateInfo, reloadIfIdle, close };
	}
}
