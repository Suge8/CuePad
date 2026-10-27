import Foundation

/// frontmatter 里一个顶层键的值怎么读、怎么写：YAML 标量的子集，够读各家真实技能里出现的写法（普通、单双引号、块、跨行折叠），
/// 写出的值换成任何一家的 YAML 解析器都读回同一段字。
extension SkillDocument {
  /// `first` 是冒号之后那段，`rest` 是值接着的几行（缩进的与中间的空行）。
  /// `quote` 是原来带的引号，没带为 nil。
  static func scalar(_ first: Substring, rest: [Substring]) -> (value: String, quote: Character?) {
    let head = first.trimmingCharacters(in: .whitespaces)
    switch head.first {
    case "|", ">":
      let indicator = String(head.prefix { !$0.isWhitespace })
      let explicit = indicator.first { $0.isNumber }?.wholeNumberValue
      let indent = explicit ?? rest.first { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix { $0 == " " }.count } ?? 2
      let lines = rest.map { $0.allSatisfy(\.isWhitespace) ? "" : String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
      var value = indicator.first == "|" ? lines.joined(separator: "\n") : folded(lines)
      while value.last == "\n" { value.removeLast() }
      return (value, nil)
    case "\"", "'":
      let quote = head.first!
      let raw = ([head] + rest.map(String.init)).joined(separator: "\n").dropFirst()
      return (quoted(raw, quote: quote), quote)
    default:
      // 普通写法：` #` 起是注释，跨行的每行去掉首尾空白再折叠
      let lines = ([first] + rest).map { line in
        let content = line.range(of: " #").map { line[..<$0.lowerBound] } ?? line
        return content.trimmingCharacters(in: .whitespaces)
      }
      return (folded(Array(lines.drop(while: \.isEmpty))), nil)
    }
  }

  /// 冒号后那段接着的 `rest` 里有几行属于值：引号的到收尾引号那行；块的到缩进不够的那行；普通的到值之后的注释（` #` 或单独一行的 `#`）。
  static func valueLines(_ first: Substring, rest: ArraySlice<Substring>) -> Int {
    let head = first.trimmingCharacters(in: .whitespaces)
    let blank = { (line: Substring) in line.allSatisfy { $0 == " " || $0 == "\t" } }
    switch head.first {
    case "|", ">":
      let explicit = head.first { $0.isNumber }?.wholeNumberValue
      guard let indent = explicit ?? rest.first(where: { !blank($0) }).map({ $0.prefix { $0 == " " }.count }) else { return rest.count }
      return rest.prefix { blank($0) || $0.prefix { $0 == " " }.count >= indent }.count
    case "\"", "'":
      let quote = head.first!
      var escaped = false, pendingQuote = false
      for (offset, line) in ([Substring(head.dropFirst())] + rest).enumerated() {
        for character in line {
          if pendingQuote {
            pendingQuote = false
            if character == "'" { continue }
            return offset
          }
          if escaped { escaped = false } else if quote == "\"" && character == "\\" { escaped = true } else if character == quote {
            if quote == "\"" { return offset }
            pendingQuote = true
          }
        }
        if pendingQuote { return offset }
        escaped = false
      }
      return rest.count
    default:
      // 值从下一行起时，它前面的注释行算在这个键里
      var started = !head.isEmpty && !head.hasPrefix("#"), count = 0
      if started && first.contains(" #") { return 0 }
      for line in rest {
        let content = line.trimmingCharacters(in: .whitespaces)
        if started && content.hasPrefix("#") { break }
        count += 1
        if !content.isEmpty && !content.hasPrefix("#") { started = true }
        if started && line.contains(" #") { break }
      }
      return count
    }
  }

  /// `key: 值` 的几行（用文件的换行符连起来，末尾不带换行）。多行的写成 `|-` 块（`block` 为假时不用块）；单行的能不加引号就不加，原来带引号的保留那种引号；
  /// 双引号能写下一切，是最后的写法。
  static func yaml(_ key: Key, _ value: String, quote: Character?, block: Bool, newline: String) -> String {
    let prefix = key.rawValue + ":"
    let printable = !value.unicodeScalars.contains(where: needsEscape)
    if block, printable, value.contains("\n"), let first = value.first, let last = value.last, !first.isWhitespace, !last.isWhitespace {
      let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "  " + $0 }
      return ([prefix + " |-"] + lines).joined(separator: newline)
    }
    if printable && !value.contains("\n") {
      if quote == nil && isPlain(value) { return prefix + " " + value }
      if quote == "'" || (quote == nil && (value.contains("\"") || value.contains("\\"))) {
        return prefix + " '" + value.replacingOccurrences(of: "'", with: "''") + "'"
      }
    }
    return prefix + " \"" + value.unicodeScalars.map(escaped).joined() + "\""
  }

  /// 块与普通写法的折叠：相邻两行连成一个空格，n 个空行是 n 个换行；`>` 里多缩进的行保留换行。
  private static func folded(_ lines: [String]) -> String {
    var result = "", breaks = 0, previousIndented = false, started = false
    for line in lines {
      if line.isEmpty { breaks += 1; continue }
      let indented = line.first == " " || line.first == "\t"
      if started {
        if indented || previousIndented { breaks += 1 }
        result += breaks == 0 ? " " : String(repeating: "\n", count: breaks)
      }
      result += line
      started = true
      previousIndented = indented
      breaks = 0
    }
    return result
  }

  /// 引号里的字（开头的引号已去掉，读到收尾的引号为止）：换行折叠同上；单引号里 `''` 是一个 `'`，双引号里认反斜杠转义。
  private static func quoted(_ raw: Substring, quote: Character) -> String {
    var result = ""
    var rest = raw[...]
    while let character = rest.popFirst() {
      switch character {
      case quote where quote == "'" && rest.first == "'":
        rest.removeFirst()
        result.append("'")
      case quote:
        return result
      case "\n":
        while result.last == " " || result.last == "\t" { result.removeLast() }
        var breaks = 0
        while true {
          rest = rest.drop { $0 == " " || $0 == "\t" }
          guard rest.first == "\n" else { break }
          rest.removeFirst()
          breaks += 1
        }
        result += breaks == 0 ? " " : String(repeating: "\n", count: breaks)
      case "\\" where quote == "\"":
        guard let next = rest.popFirst() else { return result }
        if next == "\n" {
          rest = rest.drop { $0 == " " || $0 == "\t" }
        } else if let digits = ["x": 2, "u": 4, "U": 8][next] {
          let hex = rest.prefix(digits)
          rest = rest.dropFirst(digits)
          if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
        } else {
          result += escapes[next] ?? String(next)
        }
      default:
        result.append(character)
      }
    }
    return result
  }

  private static let escapes: [Character: String] = [
    "0": "\0", "a": "\u{07}", "b": "\u{08}", "t": "\t", "\t": "\t", "n": "\n", "v": "\u{0B}", "f": "\u{0C}", "r": "\r",
    "e": "\u{1B}", " ": " ", "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
  ]

  /// 控制字符与 YAML 1.1 也当换行的几个，只能在双引号里转义着写
  private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t") || [0x85, 0x2028, 0x2029, 0xFEFF].contains(scalar.value)
  }

  private static func escaped(_ scalar: Unicode.Scalar) -> String {
    switch scalar {
    case "\"": "\\\""
    case "\\": "\\\\"
    case "\n": "\\n"
    case "\t": "\\t"
    default: needsEscape(scalar) ? String(format: "\\u%04X", scalar.value) : String(scalar)
    }
  }

  /// 不加引号也读回同一段字：不以 YAML 的标记字符开头，不含 `: ` 与 ` #`，不会被读成布尔、空值、数字或日期
  private static func isPlain(_ value: String) -> Bool {
    guard let first = value.first, let last = value.last, !first.isWhitespace, !last.isWhitespace, last != ":",
          !value.contains("\t"), !"-?:,[]{}#&*!|>'\"%@`".contains(first) else { return false }
    guard !value.contains(": "), !value.contains(" #") else { return false }
    if Self.keywords.contains(value.lowercased()) { return false }
    return value.wholeMatch(of: /[+.]?[0-9][0-9_:.,eExXoObB+\-]*/) == nil
  }

  private static let keywords: Set<String> = [
    "true", "false", "yes", "no", "on", "off", "y", "n", "null", "~", ".inf", ".nan", "<<", "=",
  ]
}
