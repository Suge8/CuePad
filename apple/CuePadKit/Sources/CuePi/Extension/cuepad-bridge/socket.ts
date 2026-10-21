import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { handleCommand, type Command } from "./commands.ts";
import type { Session } from "./session.ts";

/** sun_path 上限 104 字节（含结尾 NUL） */
const SUN_PATH_LIMIT = 104;
/** 一行命令（含 base64 图片）的上限，超过就断开该客户端 */
const MAX_LINE_BYTES = 64 * 1024 * 1024;

/** 目录必须是"当前用户的 0700 目录"，否则拒绝（/tmp 下的目录可能被他人预先创建）。 */
function ensureSecureDirectory(dir: string): void {
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	const st = fs.lstatSync(dir);
	if (!st.isDirectory() || st.uid !== process.getuid!() || (st.mode & 0o777) !== 0o700) {
		throw new Error(`${dir} is not a directory owned by you with mode 0700`);
	}
}

async function onConnection(session: Session, socket: net.Socket) {
	socket.on("error", () => socket.destroy());
	const greeting = await session.hello();
	if (socket.destroyed) return;
	session.clients.add(socket);
	socket.on("close", () => session.clients.delete(socket));
	session.write(socket, greeting);

	let buffer = "";
	socket.setEncoding("utf8");
	socket.on("data", (chunk: string) => {
		buffer += chunk;
		if (buffer.length > MAX_LINE_BYTES) return socket.destroy();
		let newline: number;
		while ((newline = buffer.indexOf("\n")) >= 0) {
			const line = buffer.slice(0, newline);
			buffer = buffer.slice(newline + 1);
			if (!line) continue;
			let command: Command | null;
			try {
				command = JSON.parse(line);
			} catch {
				session.write(socket, { t: "ack", id: null, ok: false, error: "bad_request" });
				continue;
			}
			handleCommand(session, socket, command);
		}
	});
}

/** 会话的 socket：`<目录>/<sessionId>.<pid>.sock`（目录 0700、socket 0600）；返回关闭它的函数（向每个客户端告别、删掉 socket 文件）。 */
export function listen(session: Session, directory: string): (reason: string) => void {
	ensureSecureDirectory(directory);
	const name = path.join(directory, `${session.ctx.sessionManager.getSessionId()}.${process.pid}`);
	const file = `${name}.sock`;
	const pending = `${name}.tmp`; // 比 file 短，file 不超限它就不超
	if (Buffer.byteLength(file) >= SUN_PATH_LIMIT) throw new Error(`socket path too long: ${file}`);
	fs.rmSync(file, { force: true });
	fs.rmSync(pending, { force: true });
	let server: net.Server | undefined = net.createServer((socket) => void onConnection(session, socket));
	const own = server;
	own.on("error", () => {});
	// 在临时名上 listen、收紧成 0600，再改名进来：CuePad 盯着目录（kqueue），名字一出现就连，这时它已在 listen、权限已收紧。
	// listen 好之前已经收掉的（stop）不再改名：同一路径上可能已是接替它的那个
	own.listen(pending, () => {
		if (server !== own) return;
		fs.chmodSync(pending, 0o600);
		fs.renameSync(pending, file);
	});
	/** 删掉本会话的 socket 文件；也挂在进程退出上（进程被 SIGTERM 之外的方式结束时，Pi 不发 session_shutdown） */
	const removeSocket = () => {
		fs.rmSync(file, { force: true });
		fs.rmSync(pending, { force: true });
	};
	process.on("exit", removeSocket);

	return (reason) => {
		for (const client of session.clients) {
			session.write(client, { t: "bye", reason });
			client.end();
		}
		session.clients.clear();
		server?.close();
		server = undefined;
		process.off("exit", removeSocket);
		removeSocket();
	};
}
