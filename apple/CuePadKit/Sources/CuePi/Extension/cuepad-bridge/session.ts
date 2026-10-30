import { execFile } from "node:child_process";
import type net from "node:net";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { phaseOf, StateTracker, type Asking, type Clock, type Phase } from "./events.ts";
import { commandInfo, contextInfo, firstUserMessage, INTERNAL_COMMAND, modelInfo, reason, replyText, type Info, type Subagent } from "./info.ts";
import { IdleExit, IS_HOSTED, SelfReload } from "./lifecycle.ts";
import { preflight } from "./preflight.ts";
import { QuotaFetcher, type Quota, type QuotaWindow } from "./quota.ts";

/** 交给 CuePad 用来定位终端的环境变量 */
const TERMINAL_ENV_KEYS = ["TERM_PROGRAM", "__CFBundleIdentifier", "TMUX", "TMUX_PANE"];

type UserContent = Parameters<ExtensionAPI["sendUserMessage"]>[0];
export type Ack = (fields: object) => void;
/** 一句要开新一轮的话：交给 Pi 的内容、斜杠开头的要不要由 Pi 展开，与认它的文字（会话里落成的那条用户消息的文字）。
 * CuePad 发来的话（`send`）另带投送请求 id 与它的确认。 */
type Said = { content: UserContent; expand: boolean; text: string; id?: string; ack?: Ack; cueTurn?: { deliveryId?: string | null } };
/** FireCode 在本扩展实例的事件总线上发布的最新事实 */
export type Firecode = { inFlight: number; subagents: Subagent[] };
/** 一个扩展实例的身份：版本与 CuePad 交给它的认领标识 */
type Identity = { extensionVersion: number; launchToken: string | null };

function readTTY(): Promise<string | null> {
	return new Promise((resolve) => {
		execFile("ps", ["-o", "tty=", "-p", String(process.pid)], { encoding: "utf8" }, (error, stdout) => {
			const tty = error ? "" : stdout.trim();
			resolve(tty && tty !== "??" ? tty : null);
		});
	});
}

/** 一个终端或 RPC 会话的状态、计时、近况与轮次：事件（`events`）与 CuePad 的命令（`commands`）都改它，变了经 `commit`、`updateInfo` 发给客户端。 */
export class Session {
	readonly tracker = new StateTracker();
	readonly lifetime = new AbortController();
	fast: boolean;
	readonly clients = new Set<net.Socket>();
	/** 主会话最后一次模型回合开始的时间（`turn_start` 的时刻）：早于这一回合写进会话文件的回答，CuePad 据此认出歇下时这一轮的回答读到没有。
	 * 取每个回合而不取 agent_start：一次运行里接着处理排队的话，最后的回答出自最后一个回合 */
	turnSince: number | null = null;
	private lastKey: string;
	phase: Phase;
	since: number;
	/** 这段连续处理（离开空闲到彻底歇下，中间等你确认也算）开始的时间；空闲、出错时为 null */
	busySince: number | null;
	private readonly tty = readTTY();
	/** 会话载入时的条目数：之后多出来的是这个进程自己写的 */
	readonly loadedEntries: number;
	private info: Info;
	/**
	 * 已交给 Pi、还没观察到对应用户消息事件的那句。message_end 先于文件写入，ACK 不是持久化证明。
	 * 没有可关联事件时超时或断连都只能表示未知，不能授权自动重投；真实消息由历史读取对账。
	 */
	starting: Said | null = null;
	/** 已交给 Pi、还没落成会话里一条消息的重跑（`retry.ts`）：落成时回它的确认，同 `starting` */
	retrying: Ack | null = null;
	asking: Asking | null = null;
	/** 压缩开始时的粗状态与计时：压缩完（或失败、取消）回到同一个粗状态时，计时也回到那时的起点——
	 * 歇着时的手动压缩不是新的一轮，压完还是原来那次"做完了"，CuePad 不因此提示、也不算有新回复。 */
	beforeCompaction: Clock | null = null;
	/**
	 * 等着开新一轮的话（CuePad 送来的、会开一轮的命令），按到达先后。发给会话的话只有一条路：歇着就开新一轮，
	 * 在跑（含压缩、等你确认）就先停下这一轮，等真正歇下（`agent_settled`、压缩结束）再交给 Pi。不用 Pi 的队列：
	 * followUp 只在一轮正常做完时读出、steer 等在跑的工具做完才读，停止既不清也不读它们，排着的话会一直卡住。
	 * 一次交一句：等着的还有下一句时，刚开始的这一轮（`agent_start`）照样先停下，每句都是新的一轮。
	 * 停下到真正歇下之间（通常不到一秒）会话被关掉（退出、重新载入、换会话）时，等着的话随扩展实例丢掉，`bye` 不报它们。
	 */
	readonly pending: Said[] = [];
	readonly draft = new Draft((message) => this.broadcast(message));
	readonly quota: QuotaFetcher;
	readonly idleExit = new IdleExit();
	readonly reload: SelfReload;

	readonly pi: ExtensionAPI;
	readonly ctx: ExtensionContext;
	private readonly firecode: Firecode;
	private readonly identity: Identity;

	constructor(pi: ExtensionAPI, ctx: ExtensionContext, firecode: Firecode, identity: Identity) {
		this.pi = pi;
		this.ctx = ctx;
		this.firecode = firecode;
		this.identity = identity;
		this.fast = this.branchFast();
		const initial = this.state();
		this.lastKey = JSON.stringify([initial, this.turnSince]);
		this.phase = phaseOf(initial);
		this.since = Date.now();
		this.busySince = this.phase === "working" ? this.since : null;
		this.loadedEntries = ctx.sessionManager.getEntries().length;
		this.info = {
			name: pi.getSessionName() ?? null,
			firstMessage: firstUserMessage(ctx.sessionManager.getEntries()),
			question: null,
			subagents: firecode.subagents,
			model: null, thinking: null, fast: this.fast, models: [],
			...contextInfo(ctx),
			...commandInfo(pi),
		};
		this.quota = new QuotaFetcher(ctx, (quota) => this.reportQuota(quota));
		this.reload = new SelfReload(ctx, identity.extensionVersion, () => this.canReload(), (action) => this.runInternal(action));
	}

	private branchFast(): boolean {
		const entry = this.ctx.sessionManager.getBranch().findLast((item) => item.type === "custom" && item.customType === "cuepad-fast");
		return entry?.type === "custom" && entry.data === true;
	}

	followBranch() {
		this.fast = this.branchFast();
		this.updateInfo({ fast: this.fast });
	}

	setFast(fast: boolean) {
		if (this.fast === fast) return;
		this.fast = fast;
		this.pi.appendEntry("cuepad-fast", fast);
		this.updateInfo({ fast });
	}

	get firstMessage() { return this.info.firstMessage; }

	state() { return this.tracker.derive(this.firecode.inFlight); }

	write(socket: net.Socket, message: object) {
		if (!socket.destroyed) socket.write(JSON.stringify(message) + "\n");
	}

	broadcast(message: object) {
		for (const client of this.clients) this.write(client, message);
	}

	/** 状态没变就不发；没有客户端时只维护状态与计时，不做任何 I/O。 */
	commit(resume?: Clock) {
		const current = this.state();
		const key = JSON.stringify([current, this.turnSince]);
		if (key === this.lastKey) return;
		this.lastKey = key;
		const next = phaseOf(current);
		if (next !== this.phase) {
			const now = Date.now();
			this.since = resume?.phase === next ? resume.since : now;
			this.busySince = resume?.phase === next ? resume.busySince : next === "working" || next === "waiting" ? this.busySince ?? now : null;
			this.phase = next;
			this.idleExit.follow(this.phase);
			this.reload.whenIdle();
		}
		if (this.clients.size === 0) return;
		this.broadcast({ t: "state", state: { ...current, since: this.since, busySince: this.busySince, turnSince: this.turnSince } });
	}

	/** 歇着、没有弹窗或 SDK 待处理消息：可以重新载入扩展。 */
	private canReload() {
		return !this.lifetime.signal.aborted && (this.phase === "idle" || this.phase === "error") && !this.asking && !this.ctx.hasPendingMessages();
	}

	/** 变了的项才发，而且只发变了的那几项：模型表（几百个）与命令清单很大，上下文用量每轮都变，不能每次带上整份。
	 * 没出现的键表示不变，null 是新值；hello 带全部。 */
	updateInfo(changes: Partial<Info>) {
		const changed: Partial<Info> = {};
		for (const key of Object.keys(changes) as (keyof Info)[]) {
			if (JSON.stringify(changes[key]) !== JSON.stringify(this.info[key])) Object.assign(changed, { [key]: changes[key] });
		}
		if (Object.keys(changed).length === 0) return;
		this.info = { ...this.info, ...changed };
		this.broadcast({ t: "info", ...changed });
		if (changed.models || changed.model) this.quota.capabilities(this.info.models, this.info.model?.provider);
	}

	/** 上下文用量随每一轮、压缩、换模型、换分支变化。 */
	refreshContext() {
		this.updateInfo(contextInfo(this.ctx));
	}

	/** 命令清单只会在会话载入（`session_start`，含重载）和资源扩展后变——扩展注册的命令、提示词模板、skill；后者发生在 `session_start`
	 * 之后且没有事件，所以每次提交消息前（`before_agent_start`）取一次，而不是每一轮（`turn_end`）。 */
	async refreshCommands() {
		this.updateInfo({ ...commandInfo(this.pi), ...await modelInfo(this.pi, this.ctx) });
	}

	/** 额度不属于会话、属于账号：每次观测都发给所有客户端（一行，随每次回复），由 CuePad 记到账号上。
	 * 不在这里去重：值没变的观测也说明刚观测过，"更新于"要跟上；写不写库只由 CuePad 定（`CueStore.recordQuota`）。 */
	/** 使用这一轮开始前已报告的授权，不在响应返回后重新解析令牌、把旧响应归到新授权。 */
	observeQuota(provider: string, windows: QuotaWindow[], complete: boolean) {
		const model = this.info.model;
		const account = model?.provider === provider ? model.account : null;
		if (windows.length === 0 || account?.kind !== "oauth" || account.source || !account.scope) return;
		this.reportQuota({ provider, account, status: "observed", windows, complete });
	}

	reportQuota(quota: Quota) {
		if (this.clients.size === 0) return;
		this.broadcast({ t: "quota", ...quota });
	}

	async hello() {
		this.updateInfo(await modelInfo(this.pi, this.ctx));
		const terminalEnv: Record<string, string> = {};
		for (const key of TERMINAL_ENV_KEYS) if (process.env[key]) terminalEnv[key] = process.env[key]!;
		return {
			t: "hello",
			extensionVersion: this.identity.extensionVersion,
			sessionId: this.ctx.sessionManager.getSessionId(),
			sessionFile: this.ctx.sessionManager.getSessionFile() ?? null,
			pid: process.pid,
			cwd: this.ctx.cwd,
			mode: this.ctx.mode,
			tty: await this.tty,
			term: terminalEnv,
			state: { ...this.state(), since: this.since, busySince: this.busySince, turnSince: this.turnSince },
			launchToken: this.identity.launchToken,
			hosted: IS_HOSTED,
			...this.info,
		};
	}

	/** 以这句开新一轮（见 `pending`）。 */
	async startRound(said: Said) {
		if (this.rejectSend(said)) return;
		if (this.pending.length === 0 && this.ctx.isIdle()) return this.submit(said);
		if (!(await this.prepare(said.ack)) || this.rejectSend(said)) return;
		this.pending.push(said);
		this.stopRound();
	}

	/**
	 * 不带 deliverAs：只在歇着时交（见 `pending`），Pi 直接开始这一轮。歇着又没有等着的话时，之前交出、还没落成消息的那句
	 * 不构成未执行证据；旧等待不阻止宿主空闲时的新意图。
	 */
	private async submit(said: Said) {
		if (this.rejectSend(said) || !(await this.prepare(said.ack)) || this.rejectSend(said)) return;
		this.starting = said;
		try {
			this.pi.sendUserMessage(said.content, said.expand ? { expandPromptTemplates: true } : undefined);
		} catch (error) {
			this.starting = null;
			this.reportFailure(reason(error));
			said.ack?.({ ok: false, error: `failed: ${reason(error)}` });
		}
	}

	async prepare(ack?: Ack) {
		const failure = await preflight(this.ctx);
		if (this.lifetime.signal.aborted) return false;
		if (!failure) return true;
		this.reportFailure(failure.detail);
		ack?.({ ok: false, error: failure.code });
		return false;
	}

	/** 只上报实际观察到的错误；宿主仍忙时不能用另一个操作的错误盖掉当前轮。 */
	reportFailure(error: string) {
		this.ctx.ui.notify(error, "error");
		if (!this.ctx.isIdle()) return;
		this.tracker.active = this.pending.length > 0;
		this.tracker.settled = this.tracker.outcome = { kind: "error", error };
		this.commit();
		this.submitPending();
	}

	/** 歇下了就交出等着的下一句。下一轮事件循环再看：压缩完成的事件在 Pi 收起压缩标记之前发出。 */
	submitPending() {
		if (this.pending.length === 0) return;
		this.later("等着的话", () => {
			if (!this.ctx.isIdle()) return this.stopForPending();
			const next = this.pending.shift();
			if (next) void this.submit(next);
		});
	}

	/** 宿主可以在排队后开出新的人类轮：每次打断前以当前投影的标识重新核对。 */
	stopForPending() {
		for (let at = this.pending.length - 1; at >= 0; at--) {
			if (this.rejectSend(this.pending[at])) this.pending.splice(at, 1);
		}
		if (this.pending.length > 0) this.stopRound();
	}

	private rejectSend(said: Said) {
		if (!said.cueTurn) return false;
		// isIdle 不含 SDK 队列；公开接口没有队列来源证据，不能用当前轮的许可抢到排队用户消息之前。
		if (this.ctx.hasPendingMessages()) {
			said.ack?.({ ok: false, error: "unconfirmed_turn" });
			return true;
		}
		if (this.ctx.isIdle()) return false;
		const last = this.ctx.sessionManager.buildSessionProjection().messages.findLast((message) => message.role === "user");
		const current = (last as { cuepadDelivery?: unknown } | undefined)?.cuepadDelivery;
		const allowed = said.cueTurn.deliveryId;
		if (typeof current === "string" && allowed && current === allowed) return false;
		said.ack?.({ ok: false, error: typeof current !== "string" || !allowed ? "unconfirmed_turn" : "user_turn" });
		return true;
	}

	/**
	 * 停下这一轮：Pi 的 `ctx.abort()`，与在 Pi 里按 Esc 同一能力（也停手动压缩），只中止指挥官自己正在跑的回合，会话随后以"被中止"歇下。
	 * 等你回答的弹窗先取消（否则这一轮会一直卡在等你）。已经空闲就什么都不做；FireCode 的子代理是独立会话，不受影响。
	 */
	stopRound() {
		this.asking?.dismiss?.();
		if (this.ctx.isIdle()) return;
		this.tracker.stopped = true;
		this.ctx.abort();
	}

	// 失败也可能早于 session_before_compact；自动压缩的结果留到真正 settled，取消不改写原结果。
	finishCompaction(error?: string) {
		if (error) this.tracker.settled = this.tracker.outcome = { kind: "error", error };
		if (!this.tracker.compacting) {
			if (error) this.commit();
			return;
		}
		const resume = this.beforeCompaction ?? undefined;
		this.beforeCompaction = null;
		this.tracker.compacting = false;
		this.commit(resume);
		this.submitPending();
	}

	/** 下一轮事件循环再触发：重载、新会话会拆掉本扩展实例并关掉连接，`ack` 要先写出去。扩展命令在 Pi 里先于"会话正忙"的检查执行，忙时也立即执行。 */
	runInternal(action: string) {
		return this.later("会话操作", () => this.pi.sendUserMessage(`/${INTERNAL_COMMAND} ${action}`, { expandPromptTemplates: true }));
	}

	/** 下一轮事件循环再交给 Pi（返回排好的这一次，可撤）。`sendUserMessage` 不返回结果：异步的失败 Pi 报在它自己的界面里；同步抛出的（本扩展实例已被换掉等）
	 * 在这里报，不让它在事件循环里成为未捕获的异常。 */
	private later(what: string, action: () => void) {
		return setImmediate(() => {
			if (this.lifetime.signal.aborted) return;
			try {
				action();
			} catch (error) {
				this.reportFailure(`CuePad：${what}没交给 Pi：${reason(error)}`);
			}
		});
	}
}

/** 正在说的话（`draft`）最多每这么久上报一次：增量在这里合并，这条说完时立即补发最后一次 */
const DRAFT_INTERVAL_MS = 100;

/**
 * 正在说的话（`draft`）：主会话当前这条助手消息到目前为止的正文，给 CuePad 逐字显示；思考与工具参数不算，FireCode 的子代理是别的会话、不经这里。
 * 增量合并到每 `DRAFT_INTERVAL_MS` 一次，这条说完时立即补发全文；它转成工具调用、被停下或出错、下一条助手消息开始时清掉（`text: null`）。
 * 正常说完的不清：CuePad 在对话（读会话文件）里出现这一条后自己换下。`since` 是这条开始出字的时刻。
 */
class Draft {
	private draft: { text: string; since: number } | null = null;
	/** 这条消息已转成工具调用：之后的正文不再算草稿 */
	private closed = false;
	private sentAt = 0;
	private timer: ReturnType<typeof setTimeout> | undefined;

	private readonly broadcast: (message: object) => void;

	constructor(broadcast: (message: object) => void) {
		this.broadcast = broadcast;
	}

	/** 一条新的助手消息开始了 */
	restart() {
		this.closed = false;
		this.clear();
	}

	/** 这条消息转成了工具调用 */
	close() {
		this.closed = true;
		this.clear();
	}

	/** `now`：这条说完了，不等合并的间隔 */
	grow(message: object, now = false) {
		const text = replyText(message);
		if (this.closed || !text || text === this.draft?.text) {
			if (now && this.timer) this.send();
			return;
		}
		this.draft = { text, since: this.draft?.since ?? Date.now() };
		if (now) return this.send();
		if (this.timer) return;
		const wait = this.sentAt + DRAFT_INTERVAL_MS - Date.now();
		if (wait <= 0) this.send();
		else this.timer = setTimeout(() => this.send(), wait);
	}

	clear() {
		if (!this.draft) return;
		this.draft = null;
		this.send();
	}

	/** 会话关闭：不再补发 */
	cancel() {
		clearTimeout(this.timer);
	}

	private send() {
		clearTimeout(this.timer);
		this.timer = undefined;
		this.sentAt = Date.now();
		this.broadcast({ t: "draft", text: this.draft?.text ?? null, since: this.draft?.since ?? null });
	}
}
