import type net from "node:net";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { account } from "./account.ts";
import { Draft } from "./draft.ts";
import { phaseOf, StateTracker, type Asking, type Clock, type Phase } from "./events.ts";
import { commandInfo, contextInfo, firstUserMessage, INTERNAL_COMMAND, modelInfo, reason, type Info, type Subagent } from "./info.ts";
import { IdleExit, SelfReload } from "./lifecycle.ts";
import { preflight } from "./preflight.ts";
import { QuotaFetcher, type Quota, type QuotaWindow } from "./quota.ts";

type UserContent = Parameters<ExtensionAPI["sendUserMessage"]>[0];
export type Ack = (fields: object) => void;
/** 一句要开新一轮的话。`text` 是认它的文字：会话里落成的那条用户消息据此认出（`landed`）。 */
type Said = { content: UserContent; expand: boolean; text: string; id?: string; ack?: Ack; cueTurn?: { deliveryId?: string | null } };
export type Firecode = { inFlight: number; subagents: Subagent[] };
type Identity = { extensionVersion: number; launchToken: string | null };

export class Session {
	readonly tracker = new StateTracker();
	readonly lifetime = new AbortController();
	fast: boolean;
	readonly clients = new Set<net.Socket>();
	/** 主会话最后一次模型回合开始的时间（`turn_start` 的时刻）：CuePad 据此认出歇下时这一轮的回答读到没有。
	 * 取每个回合而不取 agent_start：一次运行里接着处理排队的话，最后的回答出自最后一个回合 */
	turnSince: number | null = null;
	private lastKey: string;
	phase: Phase;
	since: number;
	busySince: number | null;
	private info: Info;
	/**
	 * 已交给 Pi、还没观察到对应用户消息事件的那句。message_end 先于文件写入，ACK 不是持久化证明。
	 * 没有可关联事件时超时或断连都只能表示未知，不能授权自动重投；真实消息由历史读取对账。
	 * 按交出先后排队：交出到落成之间宿主仍是空闲的，下一句照样交出，各认各的（`landed`）。
	 */
	readonly starting: Said[] = [];
	/** 同时只预检队首；预检中的消息也属于 pending，停止或结束会话可以一次收回整队。 */
	private dispatching = false;
	retrying: Ack | null = null;
	asking: Asking | null = null;
	/** 压缩开始时的粗状态与计时：压缩完（或失败、取消）回到同一个粗状态时，计时也回到那时的起点——
	 * 歇着时的手动压缩不是新的一轮，压完还是原来那次"做完了"，CuePad 不因此提示、也不算有新回复。 */
	beforeCompaction: Clock | null = null;
	/**
	 * 等着开新一轮的话（CuePad 送来的、会开一轮的命令），按到达先后。不用 Pi 的队列：
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
		this.info = {
			name: pi.getSessionName() ?? null,
			firstMessage: firstUserMessage(ctx.sessionManager.getEntries()),
			question: null,
			subagents: firecode.subagents,
			model: null, thinking: null, fast: this.fast, models: [], proofs: [],
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

	/** 没有客户端时只维护状态与计时，不做任何 I/O。 */
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

	private canReload() {
		return !this.lifetime.signal.aborted && (this.phase === "idle" || this.phase === "error") && !this.asking && !this.ctx.hasPendingMessages();
	}

	/** 只发变了的那几项：模型表（几百个）与命令清单很大，上下文用量每轮都变，不能每次带上整份。
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

	refreshContext() {
		this.updateInfo(contextInfo(this.ctx));
	}

	/** 命令清单只会在会话载入（`session_start`，含重载）和资源扩展后变；后者发生在 `session_start`
	 * 之后且没有事件，所以每次提交消息前（`before_agent_start`）取一次，而不是每一轮（`turn_end`）。 */
	async refreshCommands() {
		this.updateInfo({ ...commandInfo(this.pi), ...await modelInfo(this.pi, this.ctx) });
	}

	/** 额度不属于会话、属于账号：每次观测都发给所有客户端，由 CuePad 记到账号上。
	 * 不在这里去重：值没变的观测也说明刚观测过，"更新于"要跟上；写不写库只由 CuePad 定（`CueStore.recordQuota`）。
	 * 回复实际用的授权扩展拿不到：回合前已报告的分区与收到回复后重新解析的一致才归到它；两次之间换了账号或令牌就丢掉这次并重报模型身份，
	 * 不把新账号的用量记到旧账号上，也不把旧回复归到新授权。解析不挡回复流。 */
	observeQuota(provider: string, windows: QuotaWindow[], complete: boolean) {
		const model = this.ctx.model;
		const before = this.info.model?.provider === provider ? this.info.model.account : null;
		if (windows.length === 0 || model?.provider !== provider || before?.kind !== "oauth" || before.source || !before.scope) return;
		const receivedAt = Date.now() / 1000;
		const refreshModels = () => void modelInfo(this.pi, this.ctx).then((info) => this.updateInfo(info));
		void account(this.ctx, model).then(({ identity }) => {
			if (identity.kind !== before.kind || identity.scope !== before.scope || identity.source) return refreshModels();
			this.reportQuota({ provider, account: before, status: "observed", windows, complete, observedAt: receivedAt, requestedAt: receivedAt });
		}, refreshModels);
	}

	reportQuota(quota: Quota) {
		if (this.clients.size === 0) return;
		this.broadcast({ t: "quota", ...quota });
	}

	async hello() {
		this.updateInfo(await modelInfo(this.pi, this.ctx));
		return {
			t: "hello",
			extensionVersion: this.identity.extensionVersion,
			sessionId: this.ctx.sessionManager.getSessionId(),
			sessionFile: this.ctx.sessionManager.getSessionFile() ?? null,
			pid: process.pid,
			cwd: this.ctx.cwd,
			state: { ...this.state(), since: this.since, busySince: this.busySince, turnSince: this.turnSince },
			launchToken: this.identity.launchToken,
			hosted: true,
			...this.info,
		};
	}

	/** 所有新一轮请求先入同一队列；预检、等待宿主歇下、交出之间不转移到隐形等待队列。 */
	startRound(said: Said) {
		this.pending.push(said);
		this.submitPending();
	}

	private async dispatchNext() {
		if (this.dispatching || this.lifetime.signal.aborted) return;
		const said = this.pending[0];
		if (!said) return;
		this.dispatching = true;
		try {
			if (this.rejectSend(said)) { this.pending.shift(); return; }
			const failure = await preflight(this.ctx);
			// 等预检时可能已停止、结束或换了会话；被移出的请求已经收尾，不能再确认或交出。
			if (this.lifetime.signal.aborted || this.pending[0] !== said) return;
			if (failure) {
				this.pending.shift();
				this.reportFailure(failure.detail);
				said.ack?.({ ok: false, error: failure.code });
				return;
			}
			if (this.rejectSend(said)) { this.pending.shift(); return; }
			// 预检后的当下状态决定下一步；判断与交出之间没有 await，不依赖过去发过的歇下事件。
			if (!this.ctx.isIdle()) { this.stopRound(); return; }
			this.pending.shift();
			this.submit(said);
		} finally {
			this.dispatching = false;
			if (this.pending[0] !== said) this.submitPending();
		}
	}

	private submit(said: Said) {
		this.starting.push(said);
		try {
			this.pi.sendUserMessage(said.content, said.expand ? { expandPromptTemplates: true } : undefined);
		} catch (error) {
			this.starting.splice(this.starting.indexOf(said), 1);
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

	/** 下一轮事件循环再看：压缩完成事件早于 Pi 收起压缩标记。 */
	submitPending() {
		if (this.pending.length === 0) return;
		this.later("等着的话", () => {
			void this.dispatchNext().catch((error) => this.reportFailure(reason(error)));
		});
	}

	/** 普通停止清空尚未交出的整队，包含正在预检的队首；按回合停止不调用它。 */
	abortQueued() {
		for (const said of this.pending.splice(0)) said.ack?.({ ok: false, error: "failed: aborted before it started" });
	}

	/** 先交的先认。模板与 skill 落成的是展开后的文字，认不出原话，取最早的：它们只经 `submit` 在歇着时交出，交出后的第一条你的消息就当是它。
	 * 排在它前面的没认到的就是没落成，不再等。 */
	landed(text: string): Said | undefined {
		const at = this.starting.findIndex((said) => said.expand || text.startsWith(said.text));
		return at < 0 ? undefined : this.starting.splice(0, at + 1)[at];
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

	/** 核对投送身份与停止之间没有 await；不清空别人的 pending。
	 * starting / SDK 待处理消息尚未有可证实的当前身份，拒绝而不冒险停止新工作。 */
	stopDelivery(deliveryId: string, turnStartedAt: number): boolean {
		if (this.turnSince !== turnStartedAt) return false;
		if (this.starting.length || this.ctx.hasPendingMessages()) return false;
		const last = this.ctx.sessionManager.buildSessionProjection().messages.findLast((message) => message.role === "user");
		if ((last as { cuepadDelivery?: unknown } | undefined)?.cuepadDelivery !== deliveryId) return false;
		if (this.ctx.isIdle()) return false;
		this.stopRound();
		return true;
	}

	/**
	 * Pi 的 `ctx.abort()`，与在 Pi 里按 Esc 同一能力（也停手动压缩），只中止指挥官自己正在跑的回合，会话随后以"被中止"歇下；FireCode 的子代理是独立会话，不受影响。
	 * 等你回答的弹窗先取消，否则这一轮会一直卡在等你。
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

	/** `sendUserMessage` 不返回结果：异步的失败 Pi 报在它自己的界面里；同步抛出的（本扩展实例已被换掉等）
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
