import Foundation

public struct SkillDocument: Equatable, Sendable {
  public let name: String?
  public let description: String?
  public let body: String
  private let text: String
  private let header: Header?

  enum Key: String { case name, description }

  private struct Header: Equatable, Sendable {
    let start: String.Index
    let bodyStart: String.Index
    let closed: Bool
    let fields: [Key: Field]
  }

  private struct Field: Equatable, Sendable {
    let key: Range<String.Index>
    let value: Range<String.Index>?
    let quote: Character?
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
      while index < end, lines[index].first.map({ " \t".contains($0) }) ?? true { index += 1 }
      let after = line[line.index(after: colon)...]
      let inline = !after.trimmingCharacters(in: .whitespaces).isEmpty && !after.trimmingCharacters(in: .whitespaces).hasPrefix("#")
      let valueLine = inline ? start : (start + 1..<index).first { !Self.isComment(lines[$0]) } ?? index
      let head = inline ? after : valueLine < index ? lines[valueLine] : ""
      var last = valueLine < index ? valueLine + 1 + Self.valueLines(head, rest: lines[valueLine + 1..<index]) : valueLine
      while last > valueLine + 1, Self.isComment(lines[last - 1], blankOnly: true) { last -= 1 }
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

  private static func isComment(_ line: Substring, blankOnly: Bool = false) -> Bool {
    let content = line.trimmingCharacters(in: .whitespaces)
    return content.isEmpty || (!blankOnly && content.hasPrefix("#"))
  }

  private static func isFence(_ line: Substring) -> Bool {
    line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
  }

  private static func unix(_ text: some StringProtocol) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }
}
