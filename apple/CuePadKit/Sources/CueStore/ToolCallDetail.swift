import Foundation

public struct ToolCallDetail: Codable, Equatable, Sendable {
  public var command: String?
  public var diff: String?
  public var output: String
  public var clipped: Bool

  public init(command: String? = nil, diff: String? = nil, output: String = "", clipped: Bool = false) {
    self.command = command
    self.diff = diff
    self.output = output
    self.clipped = clipped
  }

  public var isEmpty: Bool { command == nil && diff == nil && output.isEmpty }

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
