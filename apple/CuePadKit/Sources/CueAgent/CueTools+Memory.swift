import CueStore
import CueText
import Foundation

extension CueTools {
  /// 命中的那一段，至多 `excerptLimit` 字：截在最少见的命中词（在这段话里出现得最少的，一样少取最长的）第一次出现处前面一点，
  /// 不从开头截——长回复的开头多半不是要找的，常见的词（"测试""完成"）也定位不到要找的地方。
  static func excerpt(_ text: String, around words: [String]) -> String {
    let flat = CueEnvelope.clip(text, Int.max), lowered = flat.lowercased()
    let ranked = words.map { $0.lowercased() }.filter { !$0.isEmpty }.map { ($0, lowered.components(separatedBy: $0).count - 1) }
      .filter { $0.1 > 0 }.min { ($0.1, -$0.0.count) < ($1.1, -$1.0.count) }
    guard let word = ranked?.0, let hit = flat.range(of: word, options: .caseInsensitive) else { return flat.clipped(excerptLimit) }
    let start = flat.index(hit.lowerBound, offsetBy: -excerptLead, limitedBy: flat.startIndex) ?? flat.startIndex
    return (start == flat.startIndex ? "" : "…") + String(flat[start...]).clipped(excerptLimit)
  }

  static let excerptLimit = 200
  static let excerptLead = 40

  func memory(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "note":
      let (line, index) = try await store.noteCueLine(try args.required("text"), source: .cue, pinned: args.bool("pin") ?? false)
      return .ok("记下了 #\(index)\(line.pinned ? "，一直记着" : "")。")
    case "recall":
      let query = try args.required("query")
      let found = try await store.recallCue(query)
      let words = CueStore.recallWords(query)
      var lines = found.lines.map { "#\($0.index) \($0.line.text)" + ($0.line.deletedAt == nil ? "" : "（已忘掉）") }
      lines += found.messages.map { "对话 \(iso($0.createdAt)) \($0.author.rawValue)：\(Self.excerpt(CueFormat.plainText($0.text), around: words))" }
      lines += found.cards.map { "\($0.isTask ? "任务" : "灵感")「\($0.heading)」（\($0.id.shortID)）" }
      lines += found.replies.map { reply in
        let name = reply.session.map(CueEnvelope.sessionName) ?? "会话（\(reply.message.sessionID.prefix(8))）"
        return "\(name) \(iso(reply.message.at)) 回复：\(Self.excerpt(reply.message.text, around: words))"
      }
      let more = found.unlisted
      let unlisted = [("记忆", more.lines), ("对话", more.messages), ("任务", more.cards), ("会话回复", more.replies)].filter { $0.1 > 0 }
      if !unlisted.isEmpty {
        lines.append("还有命中没列出：" + unlisted.map { "\($0.0) \($0.1) 条" }.joined(separator: "、") + "。要查全就加上更具体的词、换个说法再查。")
      }
      return .ok(lines.isEmpty ? "没找到。" : lines.joined(separator: "\n"))
    case "forget":
      let (line, index) = try await line(args)
      try await store.forgetCueLine(line.id)
      return .ok("忘掉了 #\(index)。")
    case "pin":
      let (line, index) = try await line(args)
      guard let pinned = args.bool("pinned") else { throw Failure("pin 要给 pinned: true 或 false") }
      try await store.pinCueLine(line.id, pinned)
      return .ok(pinned ? "#\(index) 一直记着。" : "#\(index) 不再一直记着。")
    case "remind":
      let raw = try args.required("at")
      guard let at = Self.date(raw) else { throw Failure("at 写 ISO 8601（2026-10-15T09:00:00+08:00）或 yyyy-MM-dd HH:mm（本机时区）") }
      guard at > Date() else { throw Failure("定时的第一次已经过了：\(raw)") }
      let repeats = try args.string("repeat").map { rule in
        guard let repeats = CueRepeat(rule: rule, time: at) else {
          throw Failure("repeat 写 FREQ=DAILY、FREQ=WEEKLY;BYDAY=MO,TH 或 FREQ=MONTHLY;BYMONTHDAY=1（时刻取 at 的）：\(rule)")
        }
        return repeats
      }
      let task = try await args.string("task").asyncMap { try await self.task($0) }
      // 回收站里的 `task(_:)` 已不认；完成、归档的挂上去不会再被收掉（`endCueSchedules`）
      if let task, task.completedAt != nil || task.archivedAt != nil {
        throw Failure("「\(task.heading)」已完成或已归档：定时只挂在没完成的任务上")
      }
      let (line, index) = try await store.noteCueLine(try args.required("text"), source: .cue, remindAt: at, repeats: repeats, task: task?.id)
      let kind = line.repeats.map(CueScheduleWords.repeats) ?? "一次"
      return .ok("定好了 #\(index)（\(kind)\(task.map { "，挂在「\($0.heading)」上" } ?? "")），\(iso(at)) 第一次叫醒你；不再定时就 forget 它。")
    case "zoom":
      guard let lo = args.int("lo") else { throw Failure("zoom 要给 lo（与 hi，同记忆视图里的 #lo-hi）") }
      guard let text = CueMemoryView(try await store.cueMemory()).zoom(lo: lo, hi: args.int("hi") ?? lo) else {
        throw Failure("展开不了 #\(lo)-\(args.int("hi") ?? lo)：照记忆视图或摘要里出现过的 #a-b 写，单行只给 lo")
      }
      return .ok(text)
    case let other: throw Failure("memory 没有 \(other)：可用 note / recall / zoom / forget / pin / remind")
    }
  }

  /// 整理记忆的大脑写回一块的摘要：只认此刻待合并的块（`CueMemoryView.merges`），#lo-hi 照块头写（hi 含在内）。
  func merge(_ args: Args) async throws -> Result {
    guard let lo = args.int("lo"), let hi = args.int("hi") else { throw Failure("要给 lo 与 hi：照块头的 #lo-hi 写") }
    let pending = CueMemoryView(try await store.cueMemory()).merges
    guard pending.contains(where: { $0.lo == lo && $0.hi == hi + 1 }) else {
      let blocks = pending.map { "#\($0.lo)-\($0.hi - 1)" }.joined(separator: "、")
      throw Failure("#\(lo)-\(hi) 不是待合并的块：照块头写。" + (blocks.isEmpty ? "已经没有待合并的了。" : "待合并的有 \(blocks)。"))
    }
    try await store.setCueSummary(lo: lo, hi: hi + 1, text: try args.required("text"))
    return .ok("#\(lo)-\(hi) 合成了一行。")
  }

  /// `line`：序号（可带 #）或 id。
  private func line(_ args: Args) async throws -> (CueMemoryLine, Int) {
    guard let raw = args.string("line") ?? args.int("line").map(String.init) else { throw Failure("要给 line（序号，如 12）") }
    let trimmed = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    if let index = Int(trimmed), let line = try await store.cueLine(at: index) { return (line, index) }
    if let uuid = UUID(uuidString: raw), let line = try await store.cueLine(uuid), let index = try await store.cueLineIndex(uuid) { return (line, index) }
    throw Failure("没有记忆 \(raw)：用 recall 找它的序号")
  }

  private static func date(_ raw: String) -> Date? {
    if let date = try? Date(raw, strategy: .iso8601) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: raw) { return date }
    }
    return nil
  }
}
