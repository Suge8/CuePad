// CuePad 的编译、测试、截图、测量与模拟器开关只经 apple/scripts/xc.sh，调试实例只经它起停（见 xc.sh、app.py 的头注释）。
// 绕开它：多一份冷编译、多一台反复冷启动的模拟器；自己起的 CuePad 不隔离、不受"每个检出一份"管；
// 按名字或 bundle id 起停会碰到用户正在用的正式版（它与调试构建同一个 bundle id）。这里拦下 Agent 直接这样做的命令。
// 只看每段命令的第一个词（跳过变量赋值与 env、xcrun 这类前缀），grep、日志里出现这些词不算。
import { readFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PREFIXES = new Set(["env", "command", "exec", "time", "nohup", "nice", "caffeinate", "timeout", "xcrun", "sudo"]);
const SWIFT_BLOCKED = new Set(["build", "test", "run"]);
// io、launch、terminate、spawn、list 等照常可用：xc.sh run 之后在开着的模拟器上点按、起画面（docs/verify.md）
const SIMCTL_BLOCKED = new Set(["boot", "shutdown", "create", "clone", "erase", "delete", "rename", "install", "uninstall", "upgrade"]);
const BUILD =
	"CuePad 的编译、测试、截图与模拟器开关只经 apple/scripts/xc.sh（产物目录与模拟器固定，用法见它的头注释）：" +
	"xc.sh build|test <mac|ios|ipad>、xc.sh test kit [xcodebuild 参数]、xc.sh shot|rec|run …、xc.sh check。";
const INSTANCE =
	"CuePad 调试实例只经 xc.sh shot|rec|run 起（隔离、每个检出一份、一定退出），run 起的用 xc.sh stop 收，" +
	"别的进程按自己拿到的 PID 结束。按名字或 bundle id 起停会碰到用户在用的正式版。";
// 指向 CuePad 本身：名字、bundle id 或 .app 包（不含路径里的 CuePad 检出目录名）
// bundle id 是 Signing.xcconfig 的 CUEPAD_APP_ID（唯一定义）
const APP_ID = readFileSync(new URL("../../apple/App/Config/Signing.xcconfig", import.meta.url), "utf8").match(/^CUEPAD_APP_ID *= *(\S+)/m)![1];
const CUEPAD = new RegExp(`^(?:CuePad|${APP_ID.replaceAll(".", "\\.")})$|(?:^|/)CuePad\\.app(?:/|$)`, "i");

/** 只留 shell 真正执行的结构：去掉 heredoc 正文；单引号里全是字面量，双引号里只有 $( 与反引号还会执行，其余分隔符都不切。 */
function structure(command: string): string {
	const lines = command.split("\n");
	const kept: string[] = [];
	for (let i = 0; i < lines.length; i++) {
		kept.push(lines[i]);
		const heredoc = lines[i].match(/(?:^|[^<])<<-?\s*(?!<)['"]?(\w+)['"]?/);
		if (heredoc) while (i + 1 < lines.length && lines[i + 1].trim() !== heredoc[1]) i++;
	}
	const text = kept.join("\n");
	// 栈顶是当前所在：单引号、双引号，或双引号里的 $( 与括号（那里又是要执行的代码）
	const stack: string[] = [];
	let out = "";
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		const top = stack.at(-1);
		if (top === "'") {
			if (ch === "'") stack.pop();
			out += /[|&;()`\n$]/.test(ch) ? " " : ch;
		} else if (top === '"') {
			if (ch === '"') stack.pop();
			if (ch === "$" && text[i + 1] === "(") {
				stack.push("(");
				out += "$(";
				i++;
			} else out += ch !== "`" && /[|&;()\n]/.test(ch) ? " " : ch;
		} else {
			if (ch === "'" || ch === '"' || ch === "(") stack.push(ch);
			else if (ch === ")" && top === "(") stack.pop();
			out += ch;
		}
	}
	return out;
}

function blocked(command: string): string | undefined {
	const text = structure(command);
	// 按名字或 bundle id 找到 PID 再结束：kill $(pgrep -x CuePad)、lsappinfo 之类
	if (/\bkill\b/.test(text) && /\b(?:pgrep|pidof|lsappinfo)\b[^\n]*cuepad/i.test(text)) return `不按名字找 CuePad 的 PID 再结束。${INSTANCE}`;
	for (const segment of text.split(/&&|\|\||[;|&\n()`]|\$\(/)) {
		const words = segment.trim().split(/\s+/).map((word) => word.replace(/^["']|["']$/g, ""));
		let i = 0;
		while (i < words.length && (/^\w+=/.test(words[i]) || PREFIXES.has(words[i]) || /^-|^\d+$/.test(words[i]))) i++;
		const program = words[i]?.split("/").pop();
		const sub = words[i + 1];
		const args = words.slice(i + 1);
		if (program === "xcodebuild" || program === "swift-build" || program === "swift-test") return `不直接调 ${program}。${BUILD}`;
		if (program === "swift" && SWIFT_BLOCKED.has(sub)) return `不直接调 swift ${sub}。${BUILD}`;
		if (program === "simctl" && SIMCTL_BLOCKED.has(sub)) return `不直接调 simctl ${sub}。${BUILD}`;
		if (program === "CuePad" || (program === "open" && args.some((a) => CUEPAD.test(a)))) return `不直接起 CuePad。${INSTANCE}`;
		if ((program === "killall" || program === "pkill") && args.some((a) => /cuepad/i.test(a))) return `不按名字结束 CuePad。${INSTANCE}`;
		if (program === "osascript" && /cuepad/i.test(segment)) return `不经 AppleScript 按名字操作 CuePad。${INSTANCE}`;
		if (program === "xctrace" && args.some((a) => CUEPAD.test(a)))
			return "xctrace 按名字、bundle id 或 .app 认 CuePad 会认到正式版、起出不隔离的实例：先 xc.sh run mac 拿 PID 再 xctrace record --attach <PID>，Release 构建用 CUEPAD_TRACE=<模板> xc.sh perf idle。";
	}
	return undefined;
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (event.toolName !== "bash") return undefined;
		const reason = blocked(String(event.input.command ?? ""));
		return reason ? { block: true, reason } : undefined;
	});
}
