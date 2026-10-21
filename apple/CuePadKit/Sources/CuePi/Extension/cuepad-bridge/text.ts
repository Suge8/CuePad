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
