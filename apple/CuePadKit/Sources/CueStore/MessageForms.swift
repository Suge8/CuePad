import CueText
import Foundation

public struct MessageEnvelope: Equatable, Sendable {
  public var name: String
  public var body: String

  public init(name: String, body: String) {
    self.name = name
    self.body = body
  }

  public static func parse(_ text: String) -> [MessageEnvelope]? {
    let source = text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
    var blocks: [MessageEnvelope] = []
    var location = 0
    while location < source.length {
      guard let match = block.firstMatch(in: source as String, options: .anchored, range: NSRange(location: location, length: source.length - location))
      else { return nil }
      blocks.append(MessageEnvelope(name: source.substring(with: match.range(at: 1)), body: source.substring(with: match.range(at: 2))))
      location = NSMaxRange(match.range)
    }
    return blocks.isEmpty ? nil : blocks
  }

  private static let block = try! NSRegularExpression(pattern: #"<([A-Za-z][\w.-]*)>\n((?:(?!\n</\1>)[\s\S])*)\n</\1>\s*"#)

  static func clipped(_ blocks: [MessageEnvelope], limit: Int) -> String {
    let share = limit / blocks.count
    return blocks.map { block in
      "<\(block.name)>\n\(block.body.clipped(share))\n</\(block.name)>"
    }.joined(separator: "\n")
  }
}

/// 你用斜杠技能说的一句（`/skill:名字 参数`）：Pi 把它展开成 `<skill name="名字" location="…">\n…正文…\n</skill>` 再接上参数交给模型，
/// 会话文件里只有展开后的样子。CuePad 写回你发的样子（`line`）：会话页的气泡、会话名与摘要都写它，正文收着、在气泡下点开看。
/// 展开格式随 Pi（1.3 的 `_expandSkillCommand`）；正文开头那行"References are relative to …"是给模型的，不算正文。
/// 被截断的（扩展报的首条消息只有前 `SessionName.firstMessageLimit` 个字）认得出名字就行：没有闭合标签时没有参数。
public struct SkillCall: Equatable, Sendable {
  public var name: String
  public var arguments: String
  public var body: String

  public var line: String { arguments.isEmpty ? "/skill:\(name)" : "/skill:\(name) \(arguments)" }

  public static func parse(_ text: String) -> SkillCall? {
    guard let head = text.prefixMatch(of: /<skill name="([^"]+)" location="[^"]*">\n/) else { return nil }
    let rest = text[head.range.upperBound...]
    let closing = rest.range(of: "\n</skill>")
    var body = String(rest[..<(closing?.lowerBound ?? rest.endIndex)])
    if let note = body.prefixMatch(of: /References are relative to [^\n]*\n\n?/) { body.removeSubrange(note.range) }
    let arguments = closing.map { rest[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    return SkillCall(name: String(head.1), arguments: arguments, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public static func shown(_ text: String) -> String { parse(text)?.line ?? text }
}

public enum ChatNotice: String, Sendable, CaseIterable {
  case compacted = "已压缩上下文"
  case stopped = "已停止"
  case declined = "已拒绝"
  case truncated = "回答未完成：达到输出长度上限"

  public var changesContext: Bool { self == .compacted }

  public var label: String {
    switch self {
    case .compacted: String(localized: "已压缩上下文")
    case .stopped: String(localized: "已停止")
    case .declined: String(localized: "已拒绝")
    case .truncated: String(localized: "回答未完成：达到输出长度上限")
    }
  }
}
