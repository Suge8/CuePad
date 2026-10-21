import type { Phase } from "./state.ts";

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
