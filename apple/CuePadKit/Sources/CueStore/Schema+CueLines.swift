import Foundation

extension Schema {
  /// 80 的一部分：Cue 记下的记忆去掉开头的记下时间与"他说"（这两样现在另存：`createdAt` 与 `source`，`CueMemoryLine.source`），只动开头、去完为空的留原文：
  /// - 开头的 `10-27 20:34 `、`10-27 `、`10-27发版`、`10-26 21:51已清`（月日，可带时刻）；
  /// - 开头的 `他说（10-27 12:59）：`、`他说(10-26 21:03睡前)：`、`他说：`、`他问（10-26 12:46）：`，整段去掉，这一条改记为他的话（`you`）。
  ///   "他问"那条正文只剩「原话」与 Cue 的做法，同"他说"那些一样是在转述他的话，不单留一个"问"；
  /// - 开头"标签（…）："里的那对括号（`labelBrackets`）：去掉括号里的月日、时刻与单独的"他说"，括号里没剩别的字就整对删掉，去掉了"他说"的改记为 `you`。
  ///
  /// 每台设备各自升级、不改 modifiedAt（不同步出去）：同一份数据改出同一份。
  static func plainCueLines(_ db: SQLite) throws {
    let rows = try db.query("SELECT id, text FROM cueLines WHERE source = 'cue'") { ($0.text(0), $0.text(1)) }
    for (id, text) in rows {
      let (rest, prefixHis) = strippedPrefix(text)
      let (label, labelHis) = labelBrackets(rest)
      guard label != text else { continue }
      try db.run("UPDATE cueLines SET text = ?, source = ? WHERE id = ?", [label, prefixHis || labelHis ? "you" : "cue", id])
    }
  }

  /// 去掉开头的时间与"他说"；去完为空的原样返回。
  private static func strippedPrefix(_ text: String) -> (String, Bool) {
    guard let found = cueLinePrefix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), found.range.length > 0,
      let end = Range(found.range, in: text), end.upperBound < text.endIndex
    else { return (text, false) }
    return (String(text[end.upperBound...]), found.range(at: 1).location != NSNotFound)
  }

  private static let cueLinePrefix = try! NSRegularExpression(
    pattern: #"^(?:(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?:\s+\d{1,2}:\d{2})?(?![\d:])\s*)?(他[说问]\s*(?:[（(]\d[^）)]*[）)])?\s*[：:]\s*)?"#)

  /// 第一个括号外的冒号（：或:）之前、不长于 `labelLimit` 个字的那一段里的第一对括号：去掉里面的月日、时刻与单独的"他说"（后面跟引号的不算），
  /// 剩下只有空白与标点就整对删掉（"规矩（10-19 07:16 他说）：" 成 "规矩："），还有别的字就留下（"规矩（他多次提醒，10-19 07:25）：" 成 "规矩（他多次提醒）："）。
  /// 括号里没有可去的就原样返回。
  private static func labelBrackets(_ text: String) -> (String, Bool) {
    var depth = 0
    var colon: String.Index?
    for index in text.indices {
      switch text[index] {
      case "（", "(": depth += 1
      case "）", ")": depth = max(0, depth - 1)
      case "：", ":": if depth == 0 { colon = index }
      default: break
      }
      if colon != nil { break }
    }
    guard let colon, text.distance(from: text.startIndex, to: colon) <= labelLimit,
      let open = text[..<colon].firstIndex(where: { "（(".contains($0) }),
      let close = text[open..<colon].firstIndex(where: { "）)".contains($0) })
    else { return (text, false) }
    let inner = String(text[text.index(after: open)..<close])
    let cleaned = tidy(inner)
    guard cleaned != inner else { return (text, false) }
    let his = said.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)) != nil
    let kept = cleaned.isEmpty ? "" : String(text[open]) + cleaned + String(text[close])
    return (String(text[..<open]) + kept + String(text[text.index(after: close)...]), his)
  }

  private static let labelLimit = 60

  private static let said = try! NSRegularExpression(pattern: #"他说(?![“"「『])"#)
  private static let stamps = try! NSRegularExpression(pattern: #"(?<!\d)(?:\d{4}-)?(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?!\d)|(?<!\d)\d{1,2}:\d{2}(?!\d)|他说(?![“"「『])"#)
  private static let separators = try! NSRegularExpression(pattern: #"\s*([，,、；;])[\s，,、；;]*"#)

  /// 去掉月日、时刻与单独的"他说"，收拢多出来的空白与分隔，修掉两头的空白与分隔；剩下全是空白与标点的返回空。
  private static func tidy(_ inner: String) -> String {
    var text = stamps.stringByReplacingMatches(in: inner, range: NSRange(inner.startIndex..., in: inner), withTemplate: "")
    guard text != inner else { return inner }
    text = separators.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,、；;。.")))
    return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
  }
}
