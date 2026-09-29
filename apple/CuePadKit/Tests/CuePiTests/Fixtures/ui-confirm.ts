// 测试用：/ask 命令弹出一个扩展 ui.confirm，用来触发"等待用户"状态。
export default function (pi: any) {
	pi.registerCommand("ask", {
		description: "test: open a confirm dialog",
		handler: async (_args: string, ctx: any) => {
			await ctx.ui.confirm("Proceed?", "test dialog");
		},
	});
}
