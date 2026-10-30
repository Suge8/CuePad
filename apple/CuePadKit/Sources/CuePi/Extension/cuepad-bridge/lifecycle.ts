import fs from "node:fs";
import path from "node:path";
import type { ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Phase } from "./events.ts";
import { reason } from "./info.ts";

/** CuePad 在后台托管的 Pi（RPC 模式、没有终端界面）启动时带这个环境变量，值是空闲多少秒后自己退出（格式见 CuePi README「协议」）；
 * 扩展在 hello 里带回"托管"。托管的只是这个进程：读出后存进进程内（/reload 重新载入扩展时还认得出）并从环境里删掉，
 * 否则 Agent 起的子进程（命令、里面再起的 pi）都继承它，也自认托管、空闲到点自己退出。 */
const HOSTED_ENV = "CUEPAD_HOSTED";
const HOSTED_KEY = Symbol.for("cuepad.hostedIdleSeconds");
const processScope = globalThis as { [HOSTED_KEY]?: number };
processScope[HOSTED_KEY] ??= Number(process.env[HOSTED_ENV]);
delete process.env[HOSTED_ENV];
const HOSTED_IDLE_SECONDS = processScope[HOSTED_KEY];
export const IS_HOSTED = Number.isFinite(HOSTED_IDLE_SECONDS) && HOSTED_IDLE_SECONDS > 0;

/**
 * 托管的进程空闲（这一轮做完、没有等你确认、子代理也歇下）满时限就自己退出：会话文件都在，CuePad 下次发话再恢复。
 * 进程不靠 CuePad 活着（App 退出、更新、崩溃都不影响它），所以计时也在这里。退出走给自己发 SIGTERM——Pi 对它的处理就是
 * 优雅收尾（清理后台子进程、发 session_shutdown，本扩展随之告别、删 socket）。否决 `ctx.shutdown()`：RPC 模式只在这一轮歇下
 * 或从标准输入读到下一条命令后才检查退出请求，托管进程空闲时两者都不会再发生，请求永远不生效。
 */
export class IdleExit {
	private timer: ReturnType<typeof setTimeout> | undefined;

	/** 粗状态变了：在忙就停表，歇着就开始计时（已在计时的不重来） */
	follow(phase: Phase) {
		if (!IS_HOSTED) return;
		if (phase === "working" || phase === "waiting") {
			this.cancel();
		} else {
			this.timer ??= setTimeout(() => process.kill(process.pid, "SIGTERM"), HOSTED_IDLE_SECONDS * 1000);
		}
	}

	cancel() {
		clearTimeout(this.timer);
		this.timer = undefined;
	}
}

/** 本扩展在磁盘上的目录（Pi 经 jiti 载入，按 CommonJS 给出 `__filename`）：CuePad 升级时（`AgentIntegration.install`）把整个目录原子地换成新版本 */
const OWN_DIRECTORY = path.dirname(__filename);
/** 版本号所在的入口文件 */
const ENTRY = path.join(OWN_DIRECTORY, "index.ts");

/**
 * 自己重新载入：CuePad 请本扩展核对磁盘（`upgrade`，见 CuePi README「协议」）、磁盘上的本扩展是别的版本时，
 * 就等到空闲（这一轮做完、没有等你回答的弹窗、子代理都歇下、不在压缩）经内部命令调 `ctx.reload()`：它清掉 Pi 的扩展缓存、
 * 从磁盘载入新版本，新实例重新连上 CuePad，用户不用自己 /reload；在跑的一轮不打断，歇下时（`commit` 里进入空闲）再重载。
 * 要等子代理也歇下：Pi 的重新载入是整个进程的扩展一起重来，FireCode 的子代理是进程内会话，在飞的回合会被中断。等的这段（可能几个小时）
 * CuePad 照常收发：它读得懂往前若干版扩展的格式（`PiWire.oldestExtension`），旧扩展不认的新命令回 `bad_request`。
 * 否决自己盯着扩展目录（`fs.watch`）：Bun 在 macOS 上用 FSEvents，关监听与进程退出都同步等 fseventsd 注册完，它一忙，
 * 会话关闭（闲置自退、/reload、换会话）就卡住几秒到十几秒；扩展文件只有 CuePad 写，由它来说。
 * 否决重新载入会话（`switchSession`）：同一工作目录下 Pi 复用缓存里的旧模块，载入的还是旧代码。
 */
export class SelfReload {
	private requested = false;
	private scheduled: ReturnType<typeof setImmediate> | undefined;

	private readonly ctx: ExtensionContext;
	private readonly version: number;
	private readonly canReload: () => boolean;
	private readonly runInternal: (action: string) => ReturnType<typeof setImmediate>;

	/** `canReload`：此刻歇着；`runInternal`：下一轮事件循环触发本扩展的内部命令 */
	constructor(ctx: ExtensionContext, version: number, canReload: () => boolean, runInternal: (action: string) => ReturnType<typeof setImmediate>) {
		this.ctx = ctx;
		this.version = version;
		this.canReload = canReload;
		this.runInternal = runInternal;
	}

	/** CuePad 的 `upgrade`：读磁盘上的版本，与自己不同就排上重新载入（同版本什么都不做，所以 CuePad 多说几次也不会反复重载） */
	check() {
		let source: string;
		try { source = fs.readFileSync(ENTRY, "utf8"); }
		catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.ctx.ui.notify(`CuePad 扩展升级检查失败：${reason(error)}`, "error");
			return;
		}
		const version = Number(/const EXTENSION_VERSION = (\d+);/.exec(source)?.[1]);
		this.requested ||= Number.isInteger(version) && version !== this.version;
		this.whenIdle();
	}

	/** 手动重载与升级共用空闲门，不中止宿主或进程内子代理。 */
	request() {
		this.requested = true;
		this.whenIdle();
	}

	/** 已请求重载、此刻歇着：排上一次重新载入 */
	whenIdle() {
		if (!this.requested || this.scheduled || !this.canReload()) return;
		this.scheduled = this.runInternal("reload-if-idle");
	}

	/** 内部命令 `reload-if-idle` 里：再核对一次空闲后从磁盘载入新版本。 */
	async ifIdle(command: ExtensionCommandContext) {
		if (!this.requested || !this.canReload()) {
			this.scheduled = undefined;
			return;
		}
		// session_compact 先通知扩展、再收起 Pi 的压缩标记：用它的空闲 Promise 等收尾，不轮询
		await command.waitForIdle();
		this.scheduled = undefined;
		if (!this.requested || !this.canReload() || !command.isIdle()) return;
		this.requested = false;
		await command.reload();
	}

	close() {
		clearImmediate(this.scheduled);
	}
}
