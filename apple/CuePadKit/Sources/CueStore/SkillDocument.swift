import Foundation

/// 一份 SKILL.md：开头 `---` 之间的 frontmatter 与之后的正文。读名字与说明（YAML 的简单写法：`键: 值`，带引号的去掉引号，
/// `|`、`>` 与空值接着读缩进的几行）、文件页写回（只换 name、description 与正文，其余键与行原样）都只经这里；四家最严的格式判定在 CuePi 的扫描。
/// 换行按 `\n` 读写（`\r\n` 读成 `\n`）。
public struct SkillDocument: Equatable, Sendable {
  /// frontmatter 的各行（不含两条 `---`）；开头没有 `---` 包着的一段为 nil
  private let header: [String]?
  public let name: String?
  public let description: String?
  /// 收尾那条 `---` 之后的全部；没有 frontmatter 时是全文
  public let body: String
  /// name、description 在 `header` 里占的行（写回时换掉这几行）
  private let ranges: [Key: Range<Int>]

  private enum Key: String { case name, description }

  public init(_ text: String) {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
          let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
    else {
      header = nil
      name = nil
      description = nil
      body = text.replacingOccurrences(of: "\r\n", with: "\n")
      ranges = [:]
      return
    }
    let header = Array(lines[1..<end])
    var fields: [String: String] = [:], ranges: [Key: Range<Int>] = [:]
    var index = 0
    while index < header.count {
      let line = header[index]
      let start = index
      index += 1
      guard let first = line.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") else { continue }
      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">") {
        let folded = !value.hasPrefix("|")
        var parts: [String] = []
        while index < header.count, header[index].isEmpty || header[index].first == " " || header[index].first == "\t" {
          parts.append(header[index].trimmingCharacters(in: .whitespaces))
          index += 1
        }
        value = parts.joined(separator: folded ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
        value = String(value.dropFirst().dropLast())
      }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      fields[key] = value
      if let known = Key(rawValue: key) { ranges[known] = start..<index }
    }
    self.header = header
    self.ranges = ranges
    name = fields[Key.name.rawValue]
    description = fields[Key.description.rawValue]
    body = lines[(end + 1)...].joined(separator: "\n")
  }

  /// 换掉名字、说明与正文后的全文：没变的那一项原样，其余键与行不动；原来没有 frontmatter、名字与说明又都空着时只有正文。
  public func with(name: String, description: String, body: String) -> String {
    guard var header else {
      if name.isEmpty && description.isEmpty { return body }
      let lines = [Self.line(.name, name), Self.line(.description, description)].joined(separator: "\n")
      return "---\n\(lines)\n---\n" + (body.hasPrefix("\n") ? body : "\n" + body)
    }
    // 后面的先换：前面的行号不跟着变
    let changes = [(Key.name, name, self.name), (Key.description, description, self.description)]
      .filter { $0.1 != ($0.2 ?? "") }
      .sorted { (ranges[$0.0]?.lowerBound ?? -1) > (ranges[$1.0]?.lowerBound ?? -1) }
    var missing: [String] = []
    for (key, value, _) in changes {
      if let range = ranges[key] {
        header.replaceSubrange(range, with: [Self.line(key, value)])
      } else {
        missing.insert(Self.line(key, value), at: 0)
      }
    }
    header.insert(contentsOf: missing, at: 0)
    return "---\n" + header.map { $0 + "\n" }.joined() + "---\n" + body
  }

  /// `键: 值`：值写得成 YAML 的普通写法就照写，不然加引号，两种引号都有时用折叠块（读的时候同样折回一行）。值里的换行折成空格。
  private static func line(_ key: Key, _ value: String) -> String {
    let value = value.replacingOccurrences(of: "\n", with: " ")
    if isPlain(value) { return "\(key.rawValue): \(value)" }
    if !value.contains("\"") && !value.contains("\\") { return "\(key.rawValue): \"\(value)\"" }
    if !value.contains("'") { return "\(key.rawValue): '\(value)'" }
    return "\(key.rawValue): >-\n  \(value)"
  }

  private static func isPlain(_ value: String) -> Bool {
    guard let first = value.first, let last = value.last, !first.isWhitespace, !last.isWhitespace, last != ":" else { return false }
    guard Double(value) == nil, !["true", "false", "null", "yes", "no", "~"].contains(value.lowercased()) else { return false }
    return !"-?:,[]{}#&*!|>'\"%@`".contains(first) && !value.contains(": ") && !value.contains(" #")
  }
}
