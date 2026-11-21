import CueStore

struct Opt {
  let name: String
  let value: String?
  let help: String
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

struct Command: Sendable {
  let path: [String]
  let summary: String
  var arguments = ""
  var options: [Opt] = []
  var notes = ""
  let run: @Sendable (Call) async throws -> Reply

  var name: String { path.joined(separator: " ") }

  #if os(macOS)
  static let all: [Command] = project + card + task + [search, show, live, liveSim, liveApp] + liveActions + conflicts
  #else
  static let all: [Command] = project + card + task + [search, show] + conflicts
  #endif
  static let nouns: [String] = all.map(\.path[0]).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
}

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
