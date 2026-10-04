// 测试用：/ask 弹出扩展 ui.confirm、/pick 弹出 ui.select，用来触发"等待用户"状态；答案经 notify 报出来（confirmed:… / picked:…）。
export default function (pi: any) {
	pi.registerCommand("ask", {
		description: "test: open a confirm dialog",
		handler: async (_args: string, ctx: any) => {
			const confirmed = await ctx.ui.confirm("Proceed?", "test dialog");
			ctx.ui.notify(`confirmed:${confirmed}`, "info");
		},
	});
	pi.registerCommand("pick", {
		description: "test: open a select dialog",
		handler: async (_args: string, ctx: any) => {
			const picked = await ctx.ui.select("Which one?", ["Alpha", "Beta"]);
			ctx.ui.notify(`picked:${picked}`, "info");
		},
	});
}
