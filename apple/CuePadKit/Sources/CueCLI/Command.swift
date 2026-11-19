import CueStore

/// 选项声明：帮助、解析、用法行都从它生成；`value` 为 nil 表示开关。
struct Opt {
  let name: String
  let value: String?
  let help: String
  /// 单字母的写法（`-i`），只给开关。
  var short: Character?

  init(_ name: String, _ help: String, value: String? = nil, short: Character? = nil) {
    self.name = name
    self.value = value
    self.help = help
    self.short = short
  }

  static func project(_ help: String) -> Opt { Opt("project", "\(help)（名称不分大小写，或 id）", value: "项目") }
  static let allProjects = Opt("all-projects", "不限项目（忽略当前目录绑定的项目）")
  static let body = Opt("body", "正文；省略则读 stdin。原样读写，不裁剪；stdin 为空报错，要空正文写 --body ''", value: "正文")
}

/// 一个命令：`path` 是 ["card", "add"] 这样的名词-动词（或单词命令）。帮助文本是它的唯一文档。
struct Command: Sendable {
  let path: [String]
  let summary: String
  var arguments = ""
  var options: [Opt] = []
  var notes = ""
  let run: @Sendable (Call) async throws -> Reply

  var name: String { path.joined(separator: " ") }

  // `live` 认的是本机在监听的开发服务（`LiveServers`，只有 Mac 有）；这个目标在 iOS 上也要编得过（`xc.sh test ios` 连它一起编）
  #if os(macOS)
  static let all: [Command] = project + card + task + [search, show, live] + liveActions + conflicts
  #else
  static let all: [Command] = project + card + task + [search, show] + conflicts
  #endif
  static let nouns: [String] = all.map(\.path[0]).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
}

/// 命令的输出：文本给人读，`json` 给 agent；`--json` 时只输出后者。
struct Reply {
  var text: String
  var json: any Sendable
}

struct Call {
  let args: Arguments
  let store: CueStore
  let environment: [String: String]
  let directory: String
  let stdin: StdinReader
}
