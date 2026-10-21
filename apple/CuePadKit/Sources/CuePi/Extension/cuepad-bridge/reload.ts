import fs from "node:fs";
import path from "node:path";
import type { ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { reason } from "./text.ts";

/** 本扩展在磁盘上的目录（Pi 经 jiti 载入，按 CommonJS 给出 `__filename`）：CuePad 升级时（`AgentIntegration.install`）把整个目录原子地换成新版本 */
const OWN_DIRECTORY = path.dirname(__filename);
/** 版本号所在的入口文件 */
const ENTRY = path.join(OWN_DIRECTORY, "index.ts");

/**
 * 自己重新载入：磁盘上的本扩展换成了别的版本（CuePad 升级时整目录换掉，所以盯所在的扩展目录，不盯本目录；事件驱动，不轮询），
 * 就等到空闲（这一轮做完、没有等你回答的弹窗、子代理都歇下、不在压缩）经内部命令调 `ctx.reload()`：它清掉 Pi 的扩展缓存、
 * 从磁盘载入新版本，新实例以新协议重新连上 CuePad，用户不用自己 /reload；在跑的一轮不打断，歇下时（`commit` 里进入空闲）再重载。
 * 否决重新载入会话（`switchSession`）：同一工作目录下 Pi 复用缓存里的旧模块，载入的还是旧代码。
 */
export class SelfReload {
	private watcher: fs.FSWatcher | undefined;
	private newerOnDisk = false;
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

	watch() {
		this.watcher = fs.watch(path.dirname(OWN_DIRECTORY), (_event, name) => {
			if (name !== null && name !== path.basename(OWN_DIRECTORY)) return;
			let source: string;
			try { source = fs.readFileSync(ENTRY, "utf8"); }
			catch (error) {
				this.newerOnDisk = false;
				if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.ctx.ui.notify(`CuePad 扩展升级检查失败：${reason(error)}`, "error");
				return;
			}
			const version = Number(/const EXTENSION_VERSION = (\d+);/.exec(source)?.[1]);
			this.newerOnDisk = Number.isInteger(version) && version !== this.version;
			this.whenIdle();
		});
		this.watcher.on("error", (error) => this.ctx.ui.notify(`CuePad 扩展文件监听失败：${reason(error)}`, "error"));
	}

	/** 磁盘上是别的版本、此刻歇着：排上一次重新载入 */
	whenIdle() {
		if (!this.newerOnDisk || this.scheduled || !this.canReload()) return;
		this.scheduled = this.runInternal("reload-if-idle");
	}

	/** 内部命令 `reload-if-idle` 里：再核对一次空闲后从磁盘载入新版本。 */
	async ifIdle(command: ExtensionCommandContext) {
		if (!this.newerOnDisk || !this.canReload()) {
			this.scheduled = undefined;
			return;
		}
		// session_compact 先通知扩展、再收起 Pi 的压缩标记：用它的空闲 Promise 等收尾，不轮询
		await command.waitForIdle();
		this.scheduled = undefined;
		if (!this.newerOnDisk || !this.canReload() || !command.isIdle()) return;
		this.newerOnDisk = false;
		await command.reload();
	}

	close() {
		this.watcher?.close();
		clearImmediate(this.scheduled);
	}
}
