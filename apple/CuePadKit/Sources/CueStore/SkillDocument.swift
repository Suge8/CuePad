import Foundation

/// 一份 SKILL.md：开头 `---` 之间的 frontmatter 与之后的正文。读名字与说明、文件页写回（只换 name、description 与正文）都只经这里；
/// 四家最严的格式判定在 CuePi 的扫描。
/// - 读：顶层的 `name`、`description` 按 YAML 的标量读（普通、单双引号、`|` `>` 块与跨行的折叠，`SkillDocument+YAML`）；
///   块写法末尾的换行不算（名字与说明是一段字，不是文件）。没有收尾 `---` 的不算 frontmatter，整份是正文。
/// - 写：没改的那一项、其余键、注释、空行与换行符（`\r\n` 的文件写回仍是 `\r\n`）一个字节不动；改了的只换掉那个键占的几行，
///   原来没有的加在 frontmatter 第一行。三样都没改时写回的就是原文（文件页据此判断有没有改动）。
/// - 正文交给编辑器时换行一律是 `\n`，收尾 `---` 后的空行不算正文，写回时原样放回。
public struct SkillDocument: Equatable, Sendable {
  public let name: String?
  public let description: String?
  /// 收尾那条 `---` 之后的正文，不含紧跟着的空行（文件页的正文从第一行字起，不空出一行）；没有 frontmatter 时是全文
  public let body: String
  private let text: String
  /// frontmatter 在原文里的位置；没有为 nil
  private let header: Header?

  enum Key: String { case name, description }

  private struct Header: Equatable, Sendable {
    /// frontmatter 第一行的起点（开头那条 `---` 之后）：新加的键写在这里
    let start: String.Index
    /// 正文的起点（收尾 `---` 与其后空行之后）
    let bodyStart: String.Index
    /// 收尾那条 `---` 后面还有换行（没有时正文要先补一个）
    let closed: Bool
    let fields: [Key: Field]
  }

  /// 一个键占的几行（键那行起，到值的最后一行，不含行尾换行）与它原来带的引号
  private struct Field: Equatable, Sendable {
    let range: Range<String.Index>
    let quote: Character?
  }

  public init(_ text: String) {
    self.text = text
    let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
    guard let opening = lines.first, Self.isFence(opening), let end = lines.indices.dropFirst().first(where: { Self.isFence(lines[$0]) })
    else {
      header = nil
      name = nil
      description = nil
      body = Self.unix(text)
      return
    }
    var fields: [Key: Field] = [:], values: [Key: String] = [:]
    var index = 1
    while index < end {
      let line = lines[index]
      let start = index
      index += 1
      guard let first = line.first, !" \t#".contains(first), let colon = line.firstIndex(of: ":") else { continue }
      // 值接着的几行：缩进的与夹在中间的空行，末尾的空行留给下一个键
      var last = index
      while index < end, lines[index].allSatisfy({ $0 == " " || $0 == "\t" }) || " \t".contains(lines[index].first!) {
        index += 1
        if !lines[index - 1].allSatisfy({ $0 == " " || $0 == "\t" }) { last = index }
      }
      index = last
      guard let key = Key(rawValue: line[..<colon].trimmingCharacters(in: .whitespaces)) else { continue }
      let scalar = Self.scalar(line[line.index(after: colon)...], rest: Array(lines[start + 1..<last]))
      values[key] = scalar.value
      fields[key] = Field(range: line.startIndex..<lines[last - 1].endIndex, quote: scalar.quote)
    }
    var bodyLine = end + 1
    while bodyLine < lines.count - 1, lines[bodyLine].isEmpty { bodyLine += 1 }
    let bodyStart = bodyLine < lines.count && !lines[bodyLine].isEmpty ? lines[bodyLine].startIndex : text.endIndex
    header = Header(start: lines[1].startIndex, bodyStart: bodyStart, closed: end + 1 < lines.count, fields: fields)
    name = values[.name]
    description = values[.description]
    body = Self.unix(text[bodyStart...])
  }

  /// 换掉名字、说明与正文后的全文：没变的原样，其余键与行不动；原来没有 frontmatter 时，名字与说明有字的才写进新加的一段。
  public func with(name: String, description: String, body: String) -> String {
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    let start = header?.bodyStart ?? text.startIndex
    let body = body == self.body ? String(text[start...]) : Self.unix(body).replacingOccurrences(of: "\n", with: newline)
    let changes = [(Key.name, name, self.name), (.description, description, self.description)].filter { $0.1 != ($0.2 ?? "") }
    guard let header else {
      if changes.isEmpty { return body }
      let fields = changes.map { Self.yaml($0.0, $0.1, quote: nil, newline: newline) + newline }.joined()
      return "---" + newline + fields + "---" + newline + (body.hasPrefix(newline) ? "" : newline) + body
    }
    var edits: [(range: Range<String.Index>, text: String)] = []
    var added = ""
    for (key, value, _) in changes {
      if let field = header.fields[key] {
        edits.append((field.range, Self.yaml(key, value, quote: field.quote, newline: newline)))
      } else {
        added += Self.yaml(key, value, quote: nil, newline: newline) + newline
      }
    }
    if !added.isEmpty { edits.append((header.start..<header.start, added)) }
    var result = "", cursor = text.startIndex
    for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }) {
      result += text[cursor..<edit.range.lowerBound] + edit.text
      cursor = edit.range.upperBound
    }
    result += text[cursor..<header.bodyStart]
    if !header.closed && !body.isEmpty { result += newline }
    return result + body
  }

  /// 顶格的 `---`（后面只许空白）：缩进的是块写法里的字
  private static func isFence(_ line: Substring) -> Bool {
    line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
  }

  private static func unix(_ text: some StringProtocol) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }
}
