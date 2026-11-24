#if os(macOS)
import CueStore
import Foundation

extension Command {
  static let liveActions: [Command] = [
    action(
      "snapshot", "读页面：按无障碍角色与名称列出看得见的内容，能操作的带引用 [ref=a5]", arguments: "[ref]",
      options: [
        Opt("interactive", "只列能操作的元素，一行一个", short: "i"),
        Opt("find", "只列含这段文字的行和它们的上级（不分大小写）", value: "文字"),
      ],
      notes: """
        给了 ref 只读那一块。整份超过 20 KB 截掉后面的、末尾写明；大页面先用 -i 或 --find。
        同一页里元素还在，引用就不变；被页面重绘替换的元素，角色加名称唯一时接回原来的引用。
        iframe 里的内容接在 iframe 那一行下面，第一行写框的来源；里面的引用照样用。密码框不给值。
        """
    ) { call in
      guard call.args.positionals.count <= 1 else { throw CLIError.usage("最多一个 ref") }
      return LiveChannel.Args(ref: call.args.positionals.first, interactive: call.args.has("interactive"), find: call.args.value("find"))
    },
    action(
      "click", "点一个元素", arguments: "<ref>",
      notes: """
        用真实的鼠标事件点（页面里 isTrusted 为真），不动用户的指针、不抢焦点。真实事件没进到页面里时（如元素在跨域 iframe 里对不准），退回脚本合成的点击，回执里写明。
        元素被别的东西挡住、禁用、没有大小时报错，不点。
        """
    ) { call in
      try call.args.expect("ref")
      return LiveChannel.Args(ref: call.args.positionals[0])
    },
    action(
      "fill", "把输入框的值换成这段文字（React 这类受控输入照常生效）；下拉框（select）按值或标签选", arguments: "<ref> <文字>",
      notes: "清空：fill <ref> ''。复选框、单选框、按钮不是输入框，用 click。密码框在回执里只报字符数。"
    ) { call in
      try call.args.expect("ref", "文字")
      return LiveChannel.Args(ref: call.args.positionals[0], text: call.args.positionals[1])
    },
    action(
      "press", "按一个键：Enter、Tab、Escape、Backspace、方向键（ArrowDown 等）或单个字符；给了 ref 先聚焦它", arguments: "<键> [ref]",
      notes: """
        按键由脚本合成（页面里 isTrusted 为假）：页面自己的 keydown 处理照常收到；浏览器默认做的几样由 CuePad 代做——输入框里 Enter 提交表单、按钮或链接上 Enter 点它、Tab 移到下一个能聚焦的元素、单个字符与 Backspace 改输入框里的字。
        做不到：快捷键与输入法这类原生按键、悬停（CSS :hover）、拖拽。
        """
    ) { call in
      guard (1...2).contains(call.args.positionals.count) else { throw CLIError.usage("需要 <键> [ref]") }
      return LiveChannel.Args(ref: call.args.positionals.dropFirst().first, key: call.args.positionals[0])
    },
    action(
      "wait", "等页面上出现一段文字、一个选择器，或地址含一段：到了就返回，超时报错",
      options: [
        Opt("text", "等这段文字出现（iframe 里的也算）", value: "文字"), Opt("selector", "等这个 CSS 选择器有看得见的元素", value: "选择器"),
        Opt("url", "等页面地址含这一段", value: "片段"), Opt("timeout", "最多等几秒，默认 10，最多 120", value: "秒"),
      ]
    ) { call in
      try call.args.expect()
      let given = ["text", "selector", "url"].filter { call.args.value($0) != nil }
      guard given.count == 1 else { throw CLIError.usage("--text、--selector、--url 给且只给一个") }
      var timeout = 10.0
      if let text = call.args.value("timeout") {
        guard let seconds = Double(text), seconds > 0, seconds <= 120 else { throw CLIError.usage("--timeout 要 0–120 之间的秒数，收到「\(text)」") }
        timeout = seconds
      }
      return LiveChannel.Args(text: call.args.value("text"), selector: call.args.value("selector"), url: call.args.value("url"), timeout: timeout)
    },
    action(
      "screenshot", "把页面此刻的画面存成 PNG（给了 ref 只截那个元素）", arguments: "[ref]",
      options: [Opt("out", "存到这个路径（相对当前目录），默认临时目录", value: "路径")],
      notes: "回执给路径与尺寸，用你读图的工具打开它。CuePad 画的高亮不入画。文件由这条命令自己写：在沙箱里，--out 要在你能写的地方。",
      saves: { call in
        call.args.value("out").map { URL(filePath: $0, relativeTo: URL(filePath: call.directory, directoryHint: .isDirectory)).standardizedFileURL }
          ?? URL.temporaryDirectory.appending(path: "cuepad-live-\(Int(Date().timeIntervalSince1970 * 1000)).png")
      }
    ) { call in
      guard call.args.positionals.count <= 1 else { throw CLIError.usage("最多一个 ref") }
      return LiveChannel.Args(ref: call.args.positionals.first)
    },
    action(
      "console", "页面的控制台报错与警告、未捕获的异常、失败的请求、网页弹的对话框：默认只给上次读之后新的",
      options: [Opt("all", "从页面载入起的全部，连 log、info 也列（最近 200 条）")]
    ) { call in
      try call.args.expect()
      return LiveChannel.Args(all: call.args.has("all"))
    },
    action(
      "upload", "给文件框（input type=file，快照里带 [file] 的那个）交文件", arguments: "<ref> <文件…>",
      notes: "文件路径相对当前目录；由这条命令读出内容交给页面，合计最多 \(LiveChannel.uploadLimit / 1_000_000) MB。"
    ) { call in
      guard call.args.positionals.count >= 2 else { throw CLIError.usage("需要 <ref> <文件…>") }
      let directory = URL(filePath: call.directory, directoryHint: .isDirectory)
      let files = try call.args.positionals.dropFirst().map { path in
        let url = URL(filePath: path, relativeTo: directory).standardizedFileURL
        guard let data = try? Data(contentsOf: url) else { throw CLIError.invalid("读不到 \(url.path)") }
        return LiveChannel.Upload(name: url.lastPathComponent, data: data)
      }
      guard files.reduce(0, { $0 + $1.data.count }) <= LiveChannel.uploadLimit else {
        throw CLIError.invalid("文件合计超过 \(LiveChannel.uploadLimit / 1_000_000) MB，交不过去")
      }
      return LiveChannel.Args(ref: call.args.positionals[0], files: files)
    },
    action(
      "eval", "在页面里跑一段 JavaScript 函数体：可 await，return 的值按 JSON 回来（截到 8 KB）；不给代码就读 stdin", arguments: "[代码]",
      notes: "跑在页面自己的上下文里，读得到页面的全局变量与 localStorage。能用 click、fill 做的不用它。"
    ) { call in
      guard call.args.positionals.count <= 1 else { throw CLIError.usage("代码作为一个参数给（加引号），或经 stdin") }
      guard let code = call.args.positionals.first ?? call.stdin(), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError.usage("给 [代码] 或经 stdin")
      }
      return LiveChannel.Args(code: code)
    },
  ]

  private static func action(
    _ name: String, _ summary: String, arguments: String = "", options: [Opt] = [], notes: String = "",
    saves: (@Sendable (Call) -> URL)? = nil, _ build: @escaping @Sendable (Call) throws -> LiveChannel.Args
  ) -> Command {
    Command(path: ["live", name], summary: summary, arguments: arguments, options: options, notes: notes) { call in
      let session = try agentSession(call, "live \(name) 只能在 Agent 执行的命令里运行，操作的是那个会话的活预览")
      let args = try build(call)
      let reply = try askLive(call, LiveChannel.Request(session: session, op: name, args: args), name: "live \(name)")
      if reply.failed { throw CLIError.invalid(reply.text) }
      var text = reply.text, saved: String?
      if let file = reply.file, let saves {
        let url = saves(call)
        do { try file.write(to: url) } catch { throw CLIError.invalid("存不进 \(url.path)：\(error.localizedDescription)") }
        saved = url.path
        text = "存到 \(url.path)（\(reply.text)）"
      }
      var json: JSONObject = ["text": text]
      if let info = reply.info {
        let fields: [(String, (any Sendable)?)] = [
          ("url", info.url), ("title", info.title), ("path", saved), ("width", info.width), ("height", info.height), ("bytes", info.bytes),
        ]
        for case let (key, value?) in fields { json[key] = value }
      }
      return Reply(text: text.hasSuffix("\n") ? text : text + "\n", json: json)
    }
  }
}
#endif
