// 测试用：/ask 弹出扩展 ui.confirm、/pick 弹出 ui.select，用来触发"等待用户"状态。
export default function (pi: any) {
	pi.registerCommand("ask", {
		description: "test: open a confirm dialog",
		handler: async (_args: string, ctx: any) => {
			await ctx.ui.confirm("Proceed?", "test dialog");
		},
	});
	pi.registerCommand("pick", {
		description: "test: open a select dialog",
		handler: async (_args: string, ctx: any) => {
			await ctx.ui.select("Which one?", ["Alpha", "Beta"]);
		},
	});
}
