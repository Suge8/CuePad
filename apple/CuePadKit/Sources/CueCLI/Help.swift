/// 帮助是命令行的唯一文档：根帮助只教常用任务；选项与 JSON 字段在各命令的 --help 里。
enum Help {
  static let root = """
    cuepad — 读写本机 CuePad 资料库（项目、灵感、任务）

    常用：
      cuepad search 部署 脚本            查灵感与任务（每个词都要命中）
      cuepad card list                   列灵感
      printf '正文' | cuepad card add    记一条灵感（正文也可用 --body）
      cuepad task add 写发布说明          加任务
      cuepad task list                   看未完成任务
      cuepad task done <id>              完成任务
      cuepad show a.png --title 改后首页 把文件发到用户手机上看，每个文件一句标题（在 Agent 的命令里运行）

    默认范围：在绑定了目录的项目里运行时，读写默认限定该项目；--project 名称指定，--all-projects 不限；新建的不在这样的目录里时进项目「默认」。
    全部命令：cuepad project --help、cuepad card --help、cuepad task --help、cuepad conflicts --help
    选项与输出字段：cuepad <命令> --help，例如 cuepad card add --help
    --json 输出 JSON（失败时 stderr 为 {"error":{"code","message"}}）；退出码 0 成功、1 运行错误、2 用法错误。
    隔离库：CUEPAD_LIBRARY_DIR=<绝对路径>；默认是 CuePad.app 的库（需先打开过一次）；从源码编的用开发库 ~/Library/Application Support/CuePad Dev。
    cuepad hook <agent> 是 CuePad 写进 Claude Code、Codex 钩子配置的转发命令，不用手动运行。
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
    // 参数和带值的选项（--parent <任务>、--after <灵感或任务>）都是对象引用
    let kinds = ["<灵感或任务>", "<任务>", "<副本>"]
    let takesReference = ([command.arguments] + options.compactMap { $0.value.map { "<\($0)>" } })
      .contains { text in kinds.contains { text.contains($0) } }
    let reference = takesReference ? "\n对象参数写 id 或至少 4 位的唯一前缀（文本输出里的 8 位短 id 可直接用）。\n" : ""
    return "\(command.summary)\n\n用法：\(usage)\n\n选项：\n\(rows)\n\(reference)"
      + (command.notes.isEmpty ? "" : "\n\(command.notes)\n")
  }
}

/// 各命令 --help 里的输出说明：字段名的唯一定义处（测试比对它与实际 JSON 的键）。
enum Schema {
  static let project = "Project {id, name, intro, icon, color, pinned, directory, cardCount, createdAt, modifiedAt}（cardCount 是顶层灵感数）"
  static let card = "Card {id, kind, status, projectId, project, parentId, body, pinned, conflictOf, startedAt, completedAt, archivedAt, deletedAt, createdAt, modifiedAt}（kind：idea 灵感、task 任务；status 只有任务有：todo 待办、inProgress 进行中（有步骤的任务，任一步骤开始过或做完就是进行中，startedAt 同此）、done 完成；parentId 是上级任务，顶层为 null，挂在任务下的任务是步骤；pinned 为 true 是项目的资料）"
  static let search = "Search {total, projects, cards}"
  static let conflict = "Conflict {original, copy}"

  /// `shape` 是顶层形状，`types` 是它用到的对象定义。
  static func output(_ shape: String, _ types: String...) -> String {
    "输出（--json）：\(shape)\n" + types.map { "  \($0)" }.joined(separator: "\n")
      + "\n  id 是小写 UUID；时间是 UTC ISO 8601 含毫秒；没有值是 null。"
  }

  static func defaultScope(otherwise fallback: String) -> String {
    "默认范围：省略时用绑定了当前目录（或其上层目录）的项目；没有则\(fallback)。"
  }

  /// 新建时没有项目可用的落点。
  static let defaultTarget = "进默认项目（id 固定，名字可改）"
}

extension String {
  /// 按显示宽度补空格（中日韩字符占两格），终端里两栏才对齐。
  var displayWidth: Int { unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) } }
  func padded(to width: Int) -> String { self + String(repeating: " ", count: max(0, width - displayWidth)) }
}
