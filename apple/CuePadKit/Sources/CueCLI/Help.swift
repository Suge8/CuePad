/// 帮助是命令行的唯一文档：根帮助只教常用任务；选项与 JSON 字段在各命令的 --help 里。
enum Help {
  static let root: String = {
    let examples = [
      ("cuepad search 部署 脚本", "查灵感与任务（每个词都要命中）"),
      ("cuepad card list", "列灵感"),
      ("printf '正文' | cuepad card add", "记一条灵感（正文也可用 --body）"),
      ("cuepad task add 写发布说明", "加任务"),
      ("cuepad task list", "看未完成任务"),
      ("cuepad task done <id>", "完成任务"),
      ("cuepad show a.png --title 改后首页", "把文件发到用户手机上看（在 Agent 的命令里运行）"),
    ]
    let width = examples.map(\.0.displayWidth).max() ?? 0
    return """
      cuepad — 读写本机 CuePad 资料库（项目、灵感、任务），把文件发到用户手机上

      常用：
      \(examples.map { "  \($0.padded(to: width))  \($1)" }.joined(separator: "\n"))

      全部命令：\(Command.nouns.joined(separator: "、"))；选项与输出字段看 cuepad <命令> --help（如 cuepad card add --help）。
      默认范围：在绑定了目录的项目里运行时读写限定该项目；--project 指定，--all-projects 不限；别处新建的进默认项目。
      --json 输出 JSON（失败时 stderr 为 {"error":{"code","message"}}）；退出码 0 成功、1 运行错误、2 用法错误。
      隔离库：CUEPAD_LIBRARY_DIR=<绝对路径>；默认是 CuePad.app 的库（需先打开过一次），从源码编的用 ~/Library/Application Support/CuePad Dev。
      cuepad hook <agent> 是 CuePad 写进 Claude Code、Codex 钩子配置的转发命令，不用手动运行。
      """
  }()

  static func group(_ noun: String, _ commands: [Command]) -> String {
    let width = commands.map { $0.name.displayWidth }.max() ?? 0
    let lines = commands.map { "  \($0.name.padded(to: width))  \($0.summary)" }.joined(separator: "\n")
    return "cuepad \(noun) 的命令：\n\(lines)\n\n用 cuepad \(noun) <动词> --help 查看选项与输出字段\n"
  }

  static func command(_ command: Command) -> String {
    let options = command.options + [Opt("json", "输出 JSON")]
    let labels = options.map { "--\($0.name)" + ($0.value.map { " <\($0)>" } ?? "") }
    let width = labels.map(\.displayWidth).max() ?? 0
    let rows = zip(labels, options).map { "  \($0.padded(to: width))  \($1.help)" }.joined(separator: "\n")
    let usage = ["cuepad", command.name, command.arguments, command.options.isEmpty ? "" : "[选项]"]
      .filter { !$0.isEmpty }.joined(separator: " ")
    // 参数和带值的选项（--parent <任务>、--after <灵感或任务>）都是对象引用
    let kinds = ["<灵感或任务>", "<任务>", "<副本>"]
    let takesReference = ([command.arguments] + options.compactMap { $0.value.map { "<\($0)>" } })
      .contains { text in kinds.contains { text.contains($0) } }
    let reference = takesReference ? "\n对象参数写 id 或至少 4 位的唯一前缀（文本输出里的 8 位短 id 可直接用）。\n" : ""
    return "\(command.summary)\n\n用法：\(usage)\n\n选项：\n\(rows)\n\(reference)"
      + (command.notes.isEmpty ? "" : "\n\(command.notes)\n")
  }
}

enum Schema {
  static let project = ProjectView.fields.description("Project") + "（cardCount 是顶层灵感数）"
  static let card = CardView.fields.description("Card") + "（kind：idea 灵感、task 任务；status 只有任务有：todo 待办、inProgress 进行中（startedAt 有值；子任务推进时上级也开始，回到待办后，已完成的子任务不会让上级重新变为进行中）、done 完成；parentId 是上级任务，顶层为 null，挂在任务下的任务是子任务；pinned 为 true 是项目里置顶的灵感）"
  static let search = SearchOutput.fields.description("Search")
  static let conflict = ConflictOutput.fields.description("Conflict")

  static func output(_ shape: String, _ types: String...) -> String {
    "输出（--json）：\(shape)\n" + types.map { "  \($0)" }.joined(separator: "\n")
      + "\n  id 是小写 UUID；时间是 UTC ISO 8601 含毫秒；没有值是 null。"
  }

  static func defaultScope(otherwise fallback: String) -> String {
    "默认范围：省略时用绑定了当前目录（或其上层目录）的项目；没有则\(fallback)。"
  }

  static let defaultTarget = "进默认项目（id 固定，名字可改）"
}

extension String {
  /// 按显示宽度补空格（中日韩字符占两格），终端里两栏才对齐。
  var displayWidth: Int { unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) } }
  func padded(to width: Int) -> String { self + String(repeating: " ", count: max(0, width - displayWidth)) }
}
