// CuePad 的编译、测试、截图与模拟器开关只经 apple/scripts/xc.sh：那里全机排队（同时最多 3 个）、产物目录按检出固定、
// 模拟器按槽位固定并停用 PosterBoard（见 xc.sh、_slot.sh、_sim.sh 的头注释）。绕开它直接调就是过载、多一份冷编译、
// 多一台模拟器反复冷启动，所以这里拦下 Agent 直接调的 xcodebuild、swift build/test/run 与 simctl 的开关机、建删、装卸。
// 只看每段命令的第一个词（跳过变量赋值与 env、xcrun 这类前缀），grep、日志里出现这些词不算。
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PREFIXES = new Set(["env", "command", "exec", "time", "nohup", "nice", "caffeinate", "timeout", "xcrun"]);
const SWIFT_BLOCKED = new Set(["build", "test", "run"]);
// io、launch、terminate、spawn、list 等照常可用：xc.sh shot 之后在开着的模拟器上点按、起画面（docs/verify.md）
const SIMCTL_BLOCKED = new Set(["boot", "shutdown", "create", "clone", "erase", "delete", "rename", "install", "uninstall", "upgrade"]);
const REASON =
	"CuePad 的编译、测试、截图与模拟器开关只经 apple/scripts/xc.sh（全机排队、产物目录与模拟器固定，用法见它的头注释）：" +
	"xc.sh build|test <mac|ios|ipad>、xc.sh test kit [swift test 参数]、xc.sh shot|rec|run …、xc.sh check。";

function blocked(command: string): string | undefined {
	for (const segment of command.split(/&&|\|\||[;|&\n()`]|\$\(/)) {
		const words = segment.trim().split(/\s+/).map((word) => word.replace(/^["']|["']$/g, ""));
		let i = 0;
		while (i < words.length && (/^\w+=/.test(words[i]) || PREFIXES.has(words[i]) || /^-|^\d+$/.test(words[i]))) i++;
		const program = words[i]?.split("/").pop();
		const sub = words[i + 1];
		if (program === "xcodebuild" || program === "swift-build" || program === "swift-test") return program;
		if (program === "swift" && SWIFT_BLOCKED.has(sub)) return `swift ${sub}`;
		if (program === "simctl" && SIMCTL_BLOCKED.has(sub)) return `simctl ${sub}`;
	}
	return undefined;
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (event.toolName !== "bash") return undefined;
		const hit = blocked(String(event.input.command ?? ""));
		return hit ? { block: true, reason: `不直接调 ${hit}。${REASON}` } : undefined;
	});
}
