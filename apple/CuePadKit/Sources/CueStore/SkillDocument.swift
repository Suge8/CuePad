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

  /// 一个键在原文里占的地方与它原来带的引号。值写在下一行起时，键那行到值之间的注释、空行不在其中。
  private struct Field: Equatable, Sendable {
    /// 换成新的 `键: 值` 的那段：键那行到值的末尾（值写在下一行时只到冒号），行尾的注释不在其中
    let key: Range<String.Index>
    /// 写在下一行起的值占的几行，连同它前面那个换行：写回时删掉
    let value: Range<String.Index>?
    let quote: Character?
    /// 这个键下面还留着注释行：换成块写法会把它们读进值里
    let commented: Bool
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
      // 缩进的与夹在中间的空行接着这个键；冒号后没有值时，值从下一个不是注释、空行的行起。
      // 属于值的几行按值的写法定，前后的注释行与末尾的空行都不算
      while index < end, lines[index].first.map({ " \t".contains($0) }) ?? true { index += 1 }
      let after = line[line.index(after: colon)...]
      let inline = !after.trimmingCharacters(in: .whitespaces).isEmpty && !after.trimmingCharacters(in: .whitespaces).hasPrefix("#")
      let valueLine = inline ? start : (start + 1..<index).first { !Self.isComment(lines[$0]) } ?? index
      let head = inline ? after : valueLine < index ? lines[valueLine] : ""
      var last = valueLine < index ? valueLine + 1 + Self.valueLines(head, rest: lines[valueLine + 1..<index]) : valueLine
      while last > valueLine + 1, Self.isComment(lines[last - 1], blankOnly: true) { last -= 1 }
      // 只占键那一行的值，后面的行尾注释也留着
      let comment = inline && last == start + 1 ? Self.trailingComment(after) : nil
      let commented = comment != nil || !inline && !after.allSatisfy({ $0 == " " || $0 == "\t" })
        || (start + 1..<index).contains { ($0 < valueLine || $0 >= last) && !Self.isComment(lines[$0], blankOnly: true) }
      index = last
      guard let key = Key(rawValue: line[..<colon].trimmingCharacters(in: .whitespaces)) else { continue }
      let scalar = valueLine < last ? Self.scalar(head, rest: Array(lines[valueLine + 1..<last])) : (value: "", quote: nil)
      values[key] = scalar.value
      let keyEnd = inline ? comment ?? lines[last - 1].endIndex : Self.isComment(after, blankOnly: true) ? line.endIndex : after.startIndex
      let valueRange = !inline && valueLine < last ? lines[valueLine - 1].endIndex..<lines[last - 1].endIndex : nil
      fields[key] = Field(key: line.startIndex..<keyEnd, value: valueRange, quote: scalar.quote, commented: commented)
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
      let fields = changes.map { Self.yaml($0.0, $0.1, quote: nil, block: true, newline: newline) + newline }.joined()
      return "---" + newline + fields + "---" + newline + (body.hasPrefix(newline) ? "" : newline) + body
    }
    var edits: [(range: Range<String.Index>, text: String)] = []
    var added = ""
    for (key, value, _) in changes {
      if let field = header.fields[key] {
        edits.append((field.key, Self.yaml(key, value, quote: field.quote, block: !field.commented, newline: newline)))
        if let old = field.value { edits.append((old, "")) }
      } else {
        added += Self.yaml(key, value, quote: nil, block: true, newline: newline) + newline
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

  /// 只有空白（`blankOnly` 为假时也算只有注释）的一行：不是值
  private static func isComment(_ line: Substring, blankOnly: Bool = false) -> Bool {
    let content = line.trimmingCharacters(in: .whitespaces)
    return content.isEmpty || (!blankOnly && content.hasPrefix("#"))
  }

  /// 顶格的 `---`（后面只许空白）：缩进的是块写法里的字
  private static func isFence(_ line: Substring) -> Bool {
    line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
  }

  private static func unix(_ text: some StringProtocol) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }
}
