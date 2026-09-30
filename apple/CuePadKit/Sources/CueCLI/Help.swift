/// 帮助是命令行的唯一文档：根帮助只教常用任务；选项与 JSON 字段在各命令的 --help 里。
enum Help {
  static let root = """
    cuepad — 读写本机 CuePad 资料库（项目、卡片、任务）

    常用：
      cuepad search 部署 脚本            查卡片（每个词都要命中）
      cuepad card list                   列卡片
      printf '正文' | cuepad card add    记一张卡片（正文也可用 --body）
      cuepad task add 写发布说明          加任务
      cuepad task list                   看未完成任务
      cuepad task done <id>              完成任务

    默认项目：在绑定了目录的项目里运行时，读写默认限定该项目；--project 名称 / --inbox 指定，--all-projects 不限。
    全部命令：cuepad project --help、cuepad card --help、cuepad task --help、cuepad conflicts --help
    选项与输出字段：cuepad <命令> --help，例如 cuepad card add --help
    --json 输出 JSON（失败时 stderr 为 {"error":{"code","message"}}）；退出码 0 成功、1 运行错误、2 用法错误。
    隔离库：CUEPAD_LIBRARY_DIR=<绝对路径>；默认是 CuePad.app 的库（需先打开过一次）。
    """

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
    let reference = command.arguments.contains("<卡片>") || command.arguments.contains("<任务>") || command.arguments.contains("<副本>")
      ? "\n对象参数写 id 或至少 4 位的唯一前缀（文本输出里的 8 位短 id 可直接用）。\n" : ""
    return "\(command.summary)\n\n用法：\(usage)\n\n选项：\n\(rows)\n\(reference)"
      + (command.notes.isEmpty ? "" : "\n\(command.notes)\n")
  }
}

/// 各命令 --help 里的输出说明：字段名的唯一定义处（测试比对它与实际 JSON 的键）。
enum Schema {
  static let project = "Project {id, name, icon, color, pinned, goalCardId, directory, cardCount, createdAt, modifiedAt}"
  static let card = "Card {id, projectId, project, body, tags, favorite, conflictOf, deletedAt, createdAt, modifiedAt}"
  static let task = "Task {id, content, projectId, project, done, completedAt, createdAt, modifiedAt}"
  static let search = "Search {total, projects, cards}"
  static let conflict = "Conflict {original, copy}"

  /// `shape` 是顶层形状，`types` 是它用到的对象定义。
  static func output(_ shape: String, _ types: String...) -> String {
    "输出（--json）：\(shape)\n" + types.map { "  \($0)" }.joined(separator: "\n")
      + "\n  id 是小写 UUID；时间是 UTC ISO 8601 含毫秒；没有值是 null。"
  }

  /// 没有 --project / --inbox 时的默认范围说明。
  static func defaultProject(otherwise fallback: String) -> String {
    "默认项目：省略时用绑定了当前目录（或其上层目录）的项目；没有则\(fallback)。"
  }
}

extension String {
  /// 按显示宽度补空格（中日韩字符占两格），终端里两栏才对齐。
  var displayWidth: Int { unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) } }
  func padded(to width: Int) -> String { self + String(repeating: " ", count: max(0, width - displayWidth)) }
}
