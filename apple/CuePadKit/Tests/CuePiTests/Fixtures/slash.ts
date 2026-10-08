// 测试用：一个会把参数经 notify 报出来的扩展命令，用来证明经桥发出的斜杠命令确实被 Pi 当命令执行（而不是当普通文字发给模型）。
export default function (pi: any) {
	pi.registerCommand("shout", {
		description: "test: shout the arguments",
		handler: async (args: string, ctx: any) => {
			ctx.ui.notify(`shout:${args}`, "info");
		},
	});
}
