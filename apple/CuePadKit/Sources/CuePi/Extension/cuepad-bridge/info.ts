import type { ExtensionAPI, ExtensionContext, SessionEntry } from "@earendil-works/pi-coding-agent";
import { account, unresolvedAccount, type Account } from "./account.ts";

/** 需要"命令上下文"（切换会话、新会话、重载、克隆）的操作只能在命令处理函数里做：本扩展注册这一条内部命令 `/cuepad <动作>`，
 * 经 `sendUserMessage("/cuepad <动作>", { expandPromptTemplates: true })` 触发。只有这条内部命令本身不列进给手机的清单；
 * 内置的 /new、/clone、/reload 照常在清单里（`BUILTIN_COMMANDS`），执行时才转到它。 */
export const INTERNAL_COMMAND = "cuepad";
/** 命令清单里每条说明的字符数上限（含省略号）：skill 的说明可以很长，清单随会话记录同步，只要够选命令用 */
const COMMAND_DESCRIPTION_LIMIT = 120;
/** Pi 内置斜杠命令里能在非 TUI 下执行的（其余是终端里的选择器、弹窗或只往终端打印，没有对应接口，不列）。
 * `hint` 有值表示带参数（`required` 为必填）。名字、说明与 Pi 的 `/` 菜单一致。
 * 内置命令在 Pi 的终端里先于扩展命令匹配，这里同样先匹配。 */
export const BUILTIN_COMMANDS = [
	{ name: "compact", description: "压缩当前上下文，可附上说明", hint: "[说明]" },
	{ name: "name", description: "设置会话名", hint: "<名字>", required: true },
	{ name: "model", description: "换模型", hint: "<提供方/模型>", required: true },
	{ name: "thinking", description: "设置思考强度", hint: "<强度>", required: true },
	{ name: "new", description: "开一个新会话" },
	{ name: "clone", description: "在当前位置复制出一个新会话" },
	{ name: "reload", description: "重新载入扩展、skill、提示词模板与上下文文件" },
] as const;
export type BuiltinCommand = (typeof BUILTIN_COMMANDS)[number];
/** 子代理"在做什么"一句话的字符数上限（含省略号） */
const SUBAGENT_ACTION_LIMIT = 120;

/** Pi 的思考强度，包本身不导出这个类型 */
type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;
type Model = NonNullable<ExtensionContext["model"]>;
/** Pi 的思考强度，由弱到强（pi-ai 的 `ModelThinkingLevel`） */
const THINKING_LEVELS: readonly ThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

export function isThinkingLevel(value: unknown): value is ThinkingLevel {
	return THINKING_LEVELS.some((level) => level === value);
}

/** 手机上看的一个子代理：`state` 是 FireCode 名册的状态原文（running/review/done/failed/interrupted/idle），时刻是毫秒，
 * `model` 是名册里的模型原子（`provider/model`） */
export type Subagent = {
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

export function subagentsOf(workers: unknown): Subagent[] {
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

/** 会话名（`/name`）与首条用户消息：CuePad 据此按 Pi 会话列表的规则显示会话；其余是近况 */
export type Info = {
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
export type Question = { id: string | null; kind: string; text: string; options: string[] };

/** 会话里第一条用户消息（按文件顺序，与 Pi 会话列表一致）。 */
export function firstUserMessage(entries: SessionEntry[]): string | null {
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

function describeModel(model: Model, account: Account | null) {
	return { account, provider: model.provider, id: model.id, name: model.name ?? model.id, thinking: thinkingLevels(model), images: model.input.includes("image") };
}

/** 此刻可选的模型：与 Pi 的 /model 一致——配了范围（`--models`、`enabledModels`）就是范围内的，否则是已配好密钥的全部；当前模型总在其中。 */
function modelChoices(ctx: ExtensionContext): Model[] {
	const scoped = (ctx.scopedModels ?? []).map((entry) => entry.model);
	const choices = scoped.length > 0 ? scoped : ctx.modelRegistry.getAvailable();
	const current = ctx.model;
	return current && !choices.some((m) => m.provider === current.provider && m.id === current.id) ? [...choices, current] : choices;
}

/** 此刻的模型配置；Pi 里换了模型、强度后重新取。 */
export async function modelInfo(pi: ExtensionAPI, ctx: ExtensionContext): Promise<Pick<Info, "model" | "thinking" | "models">> {
	const choices = modelChoices(ctx);
	const current = ctx.model;
	const key = (model: Model) => JSON.stringify([model.provider, model.id]);
	const accounts = new Map<string, Account>();
	const resolve = async (model: Model) => {
		try { accounts.set(key(model), (await account(ctx, model)).identity); }
		catch (error) {
			if (model === current) ctx.ui.notify(`CuePad：无法读取 ${model.provider} 的授权身份：${reason(error)}`, "warning");
			accounts.set(key(model), unresolvedAccount(ctx, model));
		}
	};
	// 先解析当前模型；同提供方的其余模型随后共用它刚续期的凭据，照样解析，CuePad 才认得出换掉的账号与令牌（`CueStore.retainQuotaSources`）。
	// 其他提供方的 OAuth 只读认证种类，避免它们的续期网络挡住当前会话。
	if (current) await resolve(current);
	await Promise.all(choices.filter((model) => !current || key(model) !== key(current)).map(async (model) => {
		if (model.provider !== current?.provider && ctx.modelRegistry.isUsingOAuth(model)) accounts.set(key(model), unresolvedAccount(ctx, model));
		else await resolve(model);
	}));
	const describe = (model: Model) => describeModel(model, accounts.get(key(model)) ?? null);
	return {
		model: current ? describe(current) : null,
		thinking: current ? pi.getThinkingLevel() : null,
		models: choices.map(describe),
	};
}

/** 上下文余量：Pi 估算的已用 token 与当前模型的窗口（压缩后到下一次回答前 tokens 为 null）。 */
export function contextInfo(ctx: ExtensionContext): Pick<Info, "context"> {
	const usage = ctx.getContextUsage();
	return { context: usage ? { tokens: usage.tokens, window: usage.contextWindow } : null };
}

/** 此刻的命令清单。扩展命令与内置同名时内置先匹配（与 Pi 的终端一致），同名的扩展命令用不到，不列。 */
export function commandInfo(pi: ExtensionAPI): Pick<Info, "commands"> {
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
export function findModel(ctx: ExtensionContext, reference: string): Model | undefined {
	const models = modelChoices(ctx);
	const slash = reference.indexOf("/");
	const exact = slash > 0 ? models.find((m) => m.provider === reference.slice(0, slash) && m.id === reference.slice(slash + 1)) : undefined;
	if (exact) return exact;
	const byId = models.filter((m) => m.id === reference);
	return byId.length === 1 ? byId[0] : undefined;
}

/** 上报首条用户消息的字符数上限：它只用来当单行显示名，界面与 Pi 自己的会话列表都只显示一行，
 * 不必把可能几 MB 的首条消息（贴入的日志、代码）在每次连接与同步时传来传去。与 CuePi 的 `PiSessionName.firstMessageLimit` 相同。 */
const FIRST_MESSAGE_LIMIT = 200;

export function reason(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** 消息的文字部分（文字块用空格连接），与 Pi 会话列表取首条消息的方式一致。 */
export function messageText(message: object): string {
	const content = "content" in message ? message.content : undefined;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.filter((block) => block?.type === "text").map((block) => block.text).join(" ");
}

/** 助手消息到目前为止的正文：文字块按换行连接，与对话读会话文件取回答的规则一致（CuePi 的 `PiHistory`）。 */
export function replyText(message: object): string {
	const content = "content" in message && Array.isArray(message.content) ? message.content : [];
	return content.filter((block) => block?.type === "text").map((block) => block.text).join("\n");
}

export function preview(text: string): string | null {
	return text ? Array.from(text).slice(0, FIRST_MESSAGE_LIMIT).join("") : null;
}

/** 去掉首尾空白后截到 limit 个字符（超出的以省略号结尾）；空文字为 null。 */
export function clip(text: string, limit: number): string | null {
	const chars = Array.from(text.trim());
	if (chars.length === 0) return null;
	return chars.length <= limit ? chars.join("") : chars.slice(0, limit - 1).join("") + "…";
}
