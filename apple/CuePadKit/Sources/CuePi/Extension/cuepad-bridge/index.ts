// CuePad Pi bridge extension
// 由 CuePad 装成 Pi 扩展目录下的 cuepad-bridge/，升级时整个目录换掉，请勿手改。协议说明见 apple/CuePadKit/Sources/CuePi/README.md。
//
// 每个 Pi 会话在 socket 目录开一个 `<sessionId>.<pid>.sock`（目录 0700、socket 0600），协议是 JSON 行：
//   扩展 → CuePad  hello（连接后第一条，含当前状态与 info 快照）/ state（仅状态切换）/ info（变了的那几项：会话名、首条消息、近况）/ draft（正在说的话）/ quota（订阅额度的一次观测）/ ack / bye
//   CuePad → 扩展  send（文字+图片，以这句开新一轮，在跑就先打断）/ command（斜杠命令，由 Pi 展开执行）/ answer（回答等你确认的弹窗）/ config（会话名、模型、思考强度）/ end（结束会话）/ abort（停止这一轮）/ retry（把出错的那一轮原样重跑）/ quota（查一次订阅额度）
// 只在 tui/rpc 模式启用；无客户端时不做任何 socket 写入。
//
// 这里只接线：会话的状态、轮次与正在说的话在 session，Pi 事件与弹窗在 events，socket 与 CuePad 的命令在 connection，
// 上报的近况在 info，额度在 quota，重跑出错的一轮在 retry，托管自退与自己重新载入在 lifecycle。

import fs from "node:fs";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { listen } from "./connection.ts";
import { captureDialogs, follow } from "./events.ts";
import { INTERNAL_COMMAND, modelInfo, reason, subagentsOf } from "./info.ts";
import { supportsFast } from "./fast.ts";
import { trackShows, watchSession } from "./phone.ts";
import { Session, type Firecode } from "./session.ts";

const EXTENSION_VERSION = 51;

/** FireCode 发布"在飞子代理数"的频道（`{ inFlight }`）：在跑、在审，或已落定但结果事件还没交给指挥官的都算。
 * 与 FireCode 判断"会话进行中"用同一个事实 */
const FIRECODE_WORKERS_CHANNEL = "firecode:workers";
/** FireCode 发布子代理名册的频道（`{ workers }`，整份、内容变了才发，停用发空名册）：角色、状态、在做什么与时刻都取自它，
 * 不读 FireCode 的档案或会话文件 */
const FIRECODE_SUBAGENTS_CHANNEL = "firecode:subagents";
/** CuePad 在终端里开新会话时经这个环境变量交给扩展的认领标识，扩展在 hello 里带回 */
const LAUNCH_TOKEN_ENV = "CUEPAD_LAUNCH_TOKEN";
/** CuePad 问这台 Mac 上的 Pi 能用哪些模型时（`AgentIntegration.probe`）带这个环境变量：会话一开始就把模型配置写成一行
 * `{"cuepadProbe": {model, models}}`，不连 CuePad、不做别的；与会话上报的是同一份（`modelInfo`），没登录时都空。直接写描述符 1：RPC 模式把
 * `process.stdout` 改道到标准错误，护着它的协议输出。不调 `ctx.shutdown()`：RPC 模式只在读到下一条命令时才看退出请求，
 * 进程靠标准输入读到 EOF 退出 */
const PROBE_ENV = "CUEPAD_PROBE";

export default function (pi: ExtensionAPI) {
	const socketDirectory = process.env.CUEPAD_PI_SOCKET_DIR ?? `/tmp/cuepad-${process.getuid!()}`;
	/** 只属于这个进程里的第一个会话：读走后清掉，之后 /new 开的会话不带 */
	let launchToken: string | null = process.env[LAUNCH_TOKEN_ENV] || null;
	delete process.env[LAUNCH_TOKEN_ENV];
	/** FireCode 在本扩展实例的事件总线上发布的最新事实。总线随扩展实例走，FireCode 的发布与本扩展的 session_start 先后不定，
	 * 所以记在实例上，由服务中的会话读取 */
	const firecode: Firecode = { inFlight: 0, subagents: [] };
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
		live?.session.commit();
	});
	pi.events?.on(FIRECODE_SUBAGENTS_CHANNEL, (data) => {
		firecode.subagents = subagentsOf((data as { workers?: unknown } | null)?.workers);
		live?.session.updateInfo({ subagents: firecode.subagents });
	});

	pi.registerCommand(INTERNAL_COMMAND, {
		description: "CuePad 内部使用：需要命令上下文的会话操作（重新载入会话文件、新会话、重载、克隆）",
		handler: async (action, command: ExtensionCommandContext) => {
			const session = live?.session;
			try {
				switch (action.trim()) {
					case "reload-session": {
						const file = command.sessionManager.getSessionFile();
						if (file) await command.switchSession(file);
						break;
					}
					case "new": await command.newSession(); break;
					case "reload-if-idle": await live?.session.reload.ifIdle(command); break;
					case "end":
						await command.waitForIdle();
						if (session?.lifetime.signal.aborted) return;
						if (command.mode === "rpc") process.kill(process.pid, "SIGTERM");
						else command.shutdown();
						break;
					case "clone": {
						const leaf = command.sessionManager.getLeafId();
						if (leaf) await command.fork(leaf, { position: "at" });
						break;
					}
				}
			} catch (error) {
				if (!session?.lifetime.signal.aborted) session?.reportFailure(reason(error));
			}
		},
	});

	pi.on("before_provider_request", (event, ctx) => {
		if (!live?.session.fast || !supportsFast(ctx.model) || !event.payload || typeof event.payload !== "object" || Array.isArray(event.payload)) return;
		return { ...event.payload, service_tier: "priority" };
	});

	trackShows(pi);

	pi.on("session_start", async (_event, ctx) => {
		if (process.env[PROBE_ENV]) {
			// 没有配好密钥的模型（没登录）时 Pi 仍给出一个占位的当前模型，报成没有模型
			const { model, models } = ctx.modelRegistry.getAvailable().length > 0 ? await modelInfo(pi, ctx) : { model: null, models: [] };
			fs.writeSync(1, JSON.stringify({ cuepadProbe: { model, models } }) + "\n");
			return;
		}
		if (ctx.mode !== "tui" && ctx.mode !== "rpc") return;
		// Pi 在 RPC 的 new_session 上连发两次 session_start（实测 1.3.0）：先收掉前一个，同一会话只留一份 socket 与事件处理
		live?.close("new");
		live = serve(ctx, launchToken);
		launchToken = null;
	});
	pi.on("session_shutdown", (event) => {
		live?.close(event.reason);
		live = undefined;
	});

	/** 服务一个终端或 RPC 会话：开 socket、跟踪状态、托管时空闲自退；返回会话与拆掉它的函数。 */
	function serve(ctx: ExtensionContext, launchToken: string | null) {
		const session = new Session(pi, ctx, firecode, { extensionVersion: EXTENSION_VERSION, launchToken });
		const unsubscribe = [...follow(session), watchSession(pi, ctx)];
		session.idleExit.follow(session.phase);
		captureDialogs(ctx.ui, session);
		let stop: ((reason: string) => void) | undefined;
		try {
			stop = listen(session, socketDirectory);
		} catch (error) {
			ctx.ui.notify(`CuePad bridge disabled: ${reason(error)}`, "warning");
		}

		/** 会话关闭：拆掉它挂的一切——事件处理、计时、连接与 socket。 */
		function close(why: string) {
			session.lifetime.abort();
			for (const off of unsubscribe) off();
			session.retrying = null;
			session.starting = null;
			session.pending.length = 0;
			session.idleExit.cancel();
			session.reload.close();
			session.draft.cancel();
			stop?.(why);
		}

		return { session, close };
	}
}
