import Foundation

/// 一步的里面：命令全文或改动，与工具输出的末尾。不随对话写出：输出占会话体积的绝大部分，每条回答会大几倍（T3 Code、Buzz 也都是展开时才取）。
/// 点开那一步时由会话所在的 Mac 回会话里现取（`CueBridge` 的 `ToolCallDetail.read`）；别的设备点开时请那台 Mac 取了写在这一步上（`Tools.Item.detail`、`DeliveryMode.step`）。
/// 取的时候就截成界面排的那么多（`fitted`），写出去的不比看到的多。
public struct ToolCallDetail: Codable, Equatable, Sendable {
  public var command: String?
  /// 改动，一行一个记号：`-` 删、`+` 加、空格是上下文、`@@` 另起一段。
  public var diff: String?
  public var output: String
  /// 输出只留了末尾。
  public var clipped: Bool

  public init(command: String? = nil, diff: String? = nil, output: String = "", clipped: Bool = false) {
    self.command = command
    self.diff = diff
    self.output = output
    self.clipped = clipped
  }

  public var isEmpty: Bool { command == nil && diff == nil && output.isEmpty }

  /// 认得出调用 id 的几家（Pi、Claude Code、Codex 的会话文件）。OpenCode 的会话在它的库里，还没接。
  public static func reads(_ agent: Open<AgentKind>) -> Bool {
    [.known(.pi), .known(.claudeCode), .known(.codex)].contains(agent)
  }

  /// 命令与改动留开头、输出留末尾（命令的结论在最后），各至多 40 行、8000 个字符；截掉的地方留一行省略号，输出记在 `clipped` 上。
  public func fitted() -> ToolCallDetail {
    let lines = 40, width = 8_000
    func head(_ text: String) -> String {
      let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
      let kept = String(rows.prefix(lines).joined(separator: "\n").prefix(width))
      return rows.count > lines || kept.count < text.count ? kept + "\n…" : text
    }
    let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let tail = String(output.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n").suffix(width))
    return ToolCallDetail(command: command.map(head), diff: diff.map(head), output: tail, clipped: clipped || tail.count < output.count)
  }
}
