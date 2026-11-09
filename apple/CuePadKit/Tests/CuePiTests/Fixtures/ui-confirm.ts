// 测试用：触发"等待用户"状态。
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
