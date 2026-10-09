import CueStore
import Foundation

/// 选项声明：帮助、解析、用法行都从它生成；`value` 为 nil 表示开关。
struct Opt {
  let name: String
  let value: String?
  let help: String

  init(_ name: String, _ help: String, value: String? = nil) {
    self.name = name
    self.value = value
    self.help = help
  }

  static func project(_ help: String) -> Opt { Opt("project", "\(help)（名称不分大小写，或 id）", value: "项目") }
  static let inbox = Opt("inbox", "未分类（不属于任何项目）")
  static let global = Opt("global", "全局（不属于任何项目）")
  static let allProjects = Opt("all-projects", "不限项目（忽略当前目录的默认项目）")
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

  static let all: [Command] = project + card + task + [search, show] + conflicts
}

/// 命令的输出：文本给人读，`json` 给 agent；`--json` 时只输出后者。
struct Reply {
  var text: String
  var json: any Sendable
}

/// 命令运行时拿到的一切：解析好的参数、资料库、stdin。
struct Call {
  let args: Arguments
  let store: CueStore
  let environment: [String: String]
  let directory: String
  let stdin: StdinReader
}
