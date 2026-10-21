// 过渡（扩展 v38 起装成目录）：v37 及更早是单个文件 extensions/cuepad-bridge.ts，在跑的旧扩展只盯这个文件上的版本号。
// CuePad 装目录时把它换成同名的空扩展（`PiExtensionBundle.legacyStub`），旧会话看到版本变了、歇下时自己换上目录里的扩展；
// 这里在换上新扩展的会话开始时看一眼：别的会话都已是新版，就删掉空扩展，扩展目录里只剩一份。最后一个换过来的会话删掉它；
// 旧会话没换就退出了，下一个开始的会话删。CuePad 不再需要从 v37 及更早升级时（扩展 v39 起的 CuePad 普遍装上后）连同 Swift 那边一起删。

import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const OWNERSHIP_MARKER = "// CuePad Pi bridge extension";
const LEGACY_FILE = path.join(path.dirname(path.dirname(__filename)), "cuepad-bridge.ts");
/** 问一个会话版本最多等这么久；等不到的当它还是旧的，空扩展留着 */
const HELLO_TIMEOUT_MS = 2_000;

/** 会话的扩展版本（它连上后第一行 hello 里的）；socket 是没人在听的残留文件为 null（不算），等不到为 0（当旧的）。 */
function versionOf(file: string): Promise<number | null> {
	return new Promise((resolve) => {
		const socket = net.connect(file);
		let buffer = "";
		const done = (version: number | null) => { socket.destroy(); resolve(version); };
		socket.setTimeout(HELLO_TIMEOUT_MS, () => done(0));
		socket.on("error", () => done(null));
		socket.setEncoding("utf8");
		socket.on("data", (chunk: string) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			try { done(Number(JSON.parse(buffer.slice(0, newline)).extensionVersion) || 0); } catch { done(0); }
		});
	});
}

/** 空扩展在、而 socket 目录里别的会话都不比 `version` 旧时删掉它。 */
export async function retireLegacyFile(socketDirectory: string, version: number) {
	let legacy: string;
	try { legacy = fs.readFileSync(LEGACY_FILE, "utf8"); }
	catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
		throw error;
	}
	if (!legacy.startsWith(OWNERSHIP_MARKER)) return;
	const others = fs.readdirSync(socketDirectory).filter((name) => name.endsWith(".sock") && !name.endsWith(`.${process.pid}.sock`));
	const versions = await Promise.all(others.map((name) => versionOf(path.join(socketDirectory, name))));
	if (versions.some((v) => v !== null && v < version)) return;
	fs.rmSync(LEGACY_FILE, { force: true });
}
