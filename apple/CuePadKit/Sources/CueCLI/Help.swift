/// 帮助文本是命令行的唯一文档：命令表来自 `Command.all`，JSON 结构在下面一处定义。
enum Help {
  static var root: String {
    let width = Command.all.map { $0.name.displayWidth }.max() ?? 0
    let commands = Command.all.map { "  \($0.name.padded(to: width))  \($0.summary)" }.joined(separator: "\n")
    return """
      cuepad — 读写本机 CuePad 资料库（人与 agent 共用）

      用法：cuepad <名词> <动词> [选项]；cuepad <命令> --help 查看某个命令

      命令：
      \(commands)

      通用选项：
        --json      输出稳定的 JSON（默认是给人读的文本）
        -h, --help  帮助

      引用：项目用名称（不分大小写）或 id，重名时报错并列出候选；卡片、任务用 id 或至少 4 位的唯一前缀
      （文本输出里的 8 位短 id 可直接使用）。
      正文：按存储格式原样读写（分块是独占行 ---split---，图片是 ![](cuepad://img/<哈希>)），不裁剪、不加换行。
      资料库：默认是 CuePad.app 的库（需先打开过一次 App）；环境变量 CUEPAD_LIBRARY_DIR=<绝对路径> 改用隔离目录，
      不存在则创建。写入经 CuePad 自己的存储层，App 正在运行时也能同时使用。
      错误：stderr 一行说明，退出码 1 是运行错误，2 是用法错误；带 --json 时 stderr 是
      {"error":{"code","message"}}，code 取 usage / not_found / ambiguous / invalid / no_library / store。

      JSON 结构（id 为小写 UUID；时间为 UTC ISO 8601 含毫秒；没有值的字段是 null；键名固定）：
        Project {id, name, icon, color, pinned, goalCardId, directory, cardCount, createdAt, modifiedAt}
        Card {id, projectId, project, body, tags, favorite, conflictOf, deletedAt, createdAt, modifiedAt}
        Task {id, content, projectId, project, done, completedAt, createdAt, modifiedAt}
        Search {total, projects, cards}
        Conflict {original, copy}
      """
  }

  static func group(_ noun: String, _ commands: [Command]) -> String {
    let width = commands.map { $0.name.displayWidth }.max() ?? 0
    let lines = commands.map { "  \($0.name.padded(to: width))  \($0.summary)" }.joined(separator: "\n")
    return "cuepad \(noun) 的命令：\n\(lines)\n\n用 cuepad \(noun) <动词> --help 查看详情\n"
  }

  static func command(_ command: Command) -> String {
    let options = command.options + [Opt("json", "输出 JSON")]
    let labels = options.map { "--\($0.name)" + ($0.value.map { " <\($0)>" } ?? "") }
    let width = labels.map(\.displayWidth).max() ?? 0
    let rows = zip(labels, options).map { "  \($0.padded(to: width))  \($1.help)" }.joined(separator: "\n")
    let usage = ["cuepad", command.name, command.arguments, command.options.isEmpty ? "" : "[选项]"]
      .filter { !$0.isEmpty }.joined(separator: " ")
    return "\(command.summary)\n\n用法：\(usage)\n\n选项：\n\(rows)\n"
      + (command.notes.isEmpty ? "" : "\n\(command.notes)\n")
  }
}

extension String {
  /// 按显示宽度补空格（中日韩字符占两格），终端里两栏才对齐。
  fileprivate var displayWidth: Int { unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) } }
  fileprivate func padded(to width: Int) -> String { self + String(repeating: " ", count: max(0, width - displayWidth)) }
}
