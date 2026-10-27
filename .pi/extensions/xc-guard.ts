// CuePad 的编译、测试、截图、测量与模拟器开关只经 apple/scripts/xc.sh，调试实例只经它起停（见 xc.sh、app.py 的头注释）。
// 绕开它：多一份冷编译、多一台反复冷启动的模拟器；自己起的 CuePad 不隔离、不受"每个检出一份"管；
// 按名字或 bundle id 起停会碰到用户正在用的正式版（它与调试构建同一个 bundle id）；osascript 激活应用、点按会抢用户的前台。这里拦下 Agent 直接这样做的命令。
// 只看每段命令的第一个词（跳过变量赋值与 env、xcrun 这类前缀），grep、日志里出现这些词不算；只读的查询（pgrep、xcodebuild -version、读窗口信息的 osascript）放行。
import { existsSync, readFileSync, statSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PREFIXES = new Set(["env", "command", "exec", "time", "nohup", "nice", "caffeinate", "timeout", "xcrun", "sudo"]);
const SWIFT_BLOCKED = new Set(["build", "test", "run"]);
// io、launch、terminate、spawn、list 等照常可用：xc.sh run 之后在开着的模拟器上点按、起画面（docs/verify.md）
const SIMCTL_BLOCKED = new Set(["boot", "shutdown", "create", "clone", "erase", "delete", "rename", "install", "uninstall", "upgrade"]);
// 只读的 xcodebuild 查询：不编译、不动产物目录
const XCODEBUILD_READONLY = new Set(["-version", "-showsdks", "-help", "-usage"]);
const BUILD =
	"CuePad 的编译、测试、截图与模拟器开关只经 apple/scripts/xc.sh（产物目录与模拟器固定，用法见它的头注释）：" +
	"xc.sh build|test <mac|ios|ipad>、xc.sh test kit [xcodebuild 参数]、xc.sh shot|rec|run …、xc.sh check。";
const INSTANCE =
	"CuePad 调试实例只经 xc.sh shot|rec|run 起（隔离、每个检出一份、一定退出），run 起的用 xc.sh stop 收，" +
	"别的进程按自己拿到的 PID 结束。按名字或 bundle id 起停会碰到用户在用的正式版。";
const FOREGROUND =
	"AppleScript 里的 activate、set frontmost、System Events 点按会抢用户正在用的前台与键盘。" +
	"操作调试实例用 bcu（按 PID 投递，不抢前台，先 xc.sh run 拿 PID）；Finder、浏览器等别的应用只读窗口信息可以，要点按请让用户自己点；" +
	"调试实例的前台测量只经 -CuePadForeground YES（DebugForeground：用户键鼠静止 5 分钟以上才借，docs/verify.md「占前台」）。";
const ACTIVATING = /\b(?:activate|reopen|keystroke|key\s+code|click|perform\s+action|AXRaise)\b|\bset\b[^\n]*\bfrontmost\b/i;
// 指向 CuePad 本身：名字、bundle id 或 .app 包（不含路径里的 CuePad 检出目录名）
// bundle id 是 Signing.xcconfig 的 CUEPAD_APP_ID（唯一定义）
const APP_ID = readFileSync(new URL("../../apple/App/Config/Signing.xcconfig", import.meta.url), "utf8").match(/^CUEPAD_APP_ID *= *(\S+)/m)![1];
const CUEPAD = new RegExp(`^(?:CuePad|${APP_ID.replaceAll(".", "\\.")})$|(?:^|/)CuePad\\.app(?:/|$)`, "i");

/** 只留 shell 真正执行的结构：去掉 heredoc 正文（单独给出，喂给 osascript 这类读标准输入的程序）；单引号里全是字面量，双引号里只有 $( 与反引号还会执行，其余分隔符都不切。 */
function structure(command: string): { text: string; heredocs: string } {
	const lines = command.split("\n");
	const kept: string[] = [];
	const bodies: string[] = [];
	for (let i = 0; i < lines.length; i++) {
		kept.push(lines[i]);
		const heredoc = lines[i].match(/(?:^|[^<])<<-?\s*(?!<)['"]?(\w+)['"]?/);
		if (heredoc) while (i + 1 < lines.length && lines[i + 1].trim() !== heredoc[1]) bodies.push(lines[++i]);
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
	return { text: out, heredocs: bodies.join("\n") };
}

/** 这些词（引号、等号两侧拆开）里有没有指向 CuePad 本身的。 */
function namesCuePad(words: string): boolean {
	return words.split(/[\s="']+/).some((word) => CUEPAD.test(word));
}

/** 按名字或 bundle id 找到 PID 再结束：找 PID 的结果流进 kill——命令替换在 kill 的参数里、管道给 xargs kill、或先存进变量再 kill（只读的 pgrep 不算）。 */
function killsByName(text: string): boolean {
	const lookup = String.raw`(?:pgrep|pidof|lsappinfo)\b[^)\`|;&\n]*`;
	const substitution = String.raw`(?:\$\(|\`)\s*(${lookup})`;
	for (const [, found] of text.matchAll(new RegExp(String.raw`\bkill\b[^;&|\n]*${substitution}`, "g"))) if (namesCuePad(found)) return true;
	for (const [, found] of text.matchAll(new RegExp(String.raw`(${lookup})\|\s*xargs\b[^;&\n]*\bkill\b`, "g"))) if (namesCuePad(found)) return true;
	for (const [, name, loop, found] of text.matchAll(new RegExp(String.raw`(?:\b(\w+)=|\bfor\s+(\w+)\s+in\s+)${substitution}`, "g"))) {
		const variable = name ?? loop;
		if (namesCuePad(found) && new RegExp(String.raw`\bkill\b[^;&|\n]*\$\{?${variable}\b`).test(text)) return true;
	}
	return false;
}

/** osascript 要执行的脚本文本：它自己这一段里的（-e）、点名的脚本文件；没有 -e 与文件时脚本来自标准输入（管道、heredoc），看整条命令。字符串字面量去掉：窗口名里写 click 不是点按。 */
function scriptText(segment: string, command: string, heredocs: string, args: string[]): string {
	const files = args.filter((a) => !a.startsWith("-") && existsSync(a) && statSync(a).isFile() && statSync(a).size < 1e5);
	const fromStdin = !args.includes("-e") && files.length === 0;
	return [segment, heredocs, fromStdin ? command : "", ...files.map((f) => readFileSync(f, "utf8"))].join("\n").replace(/"(?:[^"\\\n]|\\.)*"/g, '""');
}

function blocked(command: string): string | undefined {
	const { text, heredocs } = structure(command);
	if (killsByName(text)) return `不按名字找 CuePad 的 PID 再结束。${INSTANCE}`;
	for (const segment of text.split(/&&|\|\||[;|&\n()`]|\$\(/)) {
		const words = segment.trim().split(/\s+/).map((word) => word.replace(/^["']|["']$/g, ""));
		let i = 0;
		while (i < words.length && (/^\w+=/.test(words[i]) || PREFIXES.has(words[i]) || /^-|^\d+$/.test(words[i]))) i++;
		const program = words[i]?.split("/").pop();
		const sub = words[i + 1];
		const args = words.slice(i + 1);
		if (program === "xcodebuild" && args.some((a) => XCODEBUILD_READONLY.has(a))) continue;
		if (program === "xcodebuild" || program === "swift-build" || program === "swift-test") return `不直接调 ${program}。${BUILD}`;
		if (program === "swift" && SWIFT_BLOCKED.has(sub)) return `不直接调 swift ${sub}。${BUILD}`;
		if (program === "simctl" && SIMCTL_BLOCKED.has(sub)) return `不直接调 simctl ${sub}。${BUILD}`;
		if (program === "CuePad" || (program === "open" && args.some((a) => CUEPAD.test(a)))) return `不直接起 CuePad。${INSTANCE}`;
		if ((program === "killall" || program === "pkill") && args.some((a) => namesCuePad(a))) return `不按名字结束 CuePad。${INSTANCE}`;
		if (program === "osascript") {
			if (namesCuePad(segment)) return `不经 AppleScript 按名字操作 CuePad。${INSTANCE}`;
			if (ACTIVATING.test(scriptText(segment, command, heredocs, args))) return FOREGROUND;
		}
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
