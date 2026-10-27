// 发到手机这件事：命令认得出用户在看的会话，回答说了图却没发时提醒一次。

import type { AgentBeforeSettleEvent, AgentBeforeSettleEventResult, ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { replyText } from "./info.ts";

/** 用户在 CuePad 里看的会话的 id，扩展设在自己所在进程的环境里、随每条命令带下去（`AgentKind.watchedSessionVariable`）。
 * FireCode 子代理与它同进程，命令里的 `PI_SESSION_ID` 是子代理自己的会话，CuePad 不列它们：只认那个，子代理发的卡就落在用户看不到的会话里 */
export const WATCHED_SESSION_ENV = "CUEPAD_SESSION_ID";

/** 发预览的命令行，与 CuePi `PiToolLog.preview` 认的是同一种写法 */
const SHOW_COMMAND = /(?:'[^']*\/|[^\s']*\/)?cuepad'?\s+show(?:\s|$)/;
/** 这个进程里最后一次发成功的时刻，进程内共用：子代理会话里发的也算（扩展每个会话载入一份，状态记在进程上） */
const LAST_SHOW = Symbol.for("cuepad.lastShowAt");
const processScope = globalThis as { [LAST_SHOW]?: number };

/** 记下这个会话里发成功的 `cuepad show`；codemode 脚本里调的 bash 也有自己的工具事件。在每种模式的会话里都记。 */
export function trackShows(pi: ExtensionAPI) {
	const running = new Set<string>();
	pi.on("tool_execution_start", (event) => {
		if (event.toolName === "bash" && SHOW_COMMAND.test(String(event.args?.command ?? ""))) running.add(event.toolCallId);
	});
	pi.on("tool_execution_end", (event) => {
		if (running.delete(event.toolCallId) && !event.isError) processScope[LAST_SHOW] = Date.now();
	});
}

const SEEN = "(?:图|截图|录屏|图片|对比图|效果图|方案图|示意图)";
/** 回答把图说成用户看得到：指着对话里的图（"图在上面""截图如下"），或说已经发到手机。只看过去时，"再发到你手机"这类打算不算 */
const CLAIMS_SHOWN = new RegExp([
	`${SEEN}(?:都|已经?|就)?(?:在|贴在|附在|放在)(?:上面|下面|上方|下方)`,
	`(?:上面|下面|上方|下方)(?:这|那)?\\s*[几两三四五六七八九十\\d]*\\s*(?:张|段|份|组)?的?${SEEN}(?!标)`,
	`${SEEN}如下|[如见]上图|如下图`,
	"(?<![没未])(?:已经?|都|也)[^。！？，,\\n会要再将]{0,4}发(?:到|给|过去|你)[^。！？\\n]{0,10}(?:手机|CuePad)",
	"(?<![没未再])发(?:到|给)了?[^。！？\\n]{0,10}(?:手机|CuePad)[^。！？\\n]{0,3}了",
	"\\b(?:sent|shared)\\b[^.\\n]{0,30}\\b(?:phone|CuePad)\\b",
	"\\b(?:screenshots?|images?|pictures?|recordings?)\\b[^.\\n]{0,20}\\b(?:above|below)\\b",
].join("|"), "i");

const REMINDER = "cuepad-show-reminder";
const REMINDER_TEXT = [
	"CuePad：这次的回答说了图在对话里或已经发到手机，但从用户上一句话到现在，这个会话（连同它的子代理）没有发成功过 `cuepad show`。",
	"用户在手机上的 CuePad 里看这个对话：工具结果里的图（截图、读进来的图片）他看不到，只有 `cuepad show` 发出的卡片会出现在对话里。",
	"现在用 `cuepad show` 把你说的那些发出去（完整命令在 cuepad 技能里），再用一句话说发了什么；说的其实是之前已发过的那批，或这次本来没有要给他看的图，就用一句话更正。",
].join("\n");

type Message = AgentBeforeSettleEvent["context"]["contextMessages"][number];

/** 歇下前：回答说图用户看得到，从用户上一句话起却没有发成功过，就补一条只给模型看的提醒、再跑一次（每句话至多一次）。 */
export function checkShown(event: AgentBeforeSettleEvent): AgentBeforeSettleEventResult | undefined {
	const messages = event.context.contextMessages;
	const answer = messages.at(-1);
	if (event.outcome !== "completed" || answer?.role !== "assistant" || !CLAIMS_SHOWN.test(replyText(answer))) return;
	const askedAt = messages.findLast((m) => m.role === "user")?.timestamp ?? 0;
	if ((processScope[LAST_SHOW] ?? 0) >= askedAt || messages.some((m) => isReminder(m) && m.timestamp >= askedAt)) return;
	return { entries: [{ type: "custom_message", customType: REMINDER, content: REMINDER_TEXT, display: false }], continue: true };
}

function isReminder(message: Message): boolean {
	return message.role === "custom" && message.customType === REMINDER;
}
