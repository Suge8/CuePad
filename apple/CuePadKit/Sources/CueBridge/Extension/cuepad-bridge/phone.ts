import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

/** 用户在 CuePad 里看的会话的 id，扩展设在自己所在进程的环境里、随每条命令带下去（`AgentKind.watchedSessionVariable`）。
 * FireCode 子代理与它同进程，命令里的 `PI_SESSION_ID` 是子代理自己的会话，CuePad 不列它们：只认那个，子代理发的卡就落在用户看不到的会话里 */
const WATCHED_SESSION_ENV = "CUEPAD_SESSION_ID";

export function watchSession(ctx: ExtensionContext): () => void {
	const sessionId = ctx.sessionManager.getSessionId();
	process.env[WATCHED_SESSION_ENV] = sessionId;
	return () => {
		if (process.env[WATCHED_SESSION_ENV] === sessionId) delete process.env[WATCHED_SESSION_ENV];
	};
}
