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
      let source: CueLineSource = args.bool("his") == true ? .you : .cue
      let replaced = try await lines(args, "replaces", allowEmpty: true)
      if let schedule = replaced.first(where: { $0.line.remindAt != nil }) {
        throw Failure("#\(schedule.index) 是定时，不能替换：改定时先 forget 它再 remind")
      }
      let pin = args.bool("pin") ?? replaced.contains { $0.line.pinned }
      let (line, index) = try await store.noteCueLine(
        try args.required("text"), source: source, pinned: pin, replacing: replaced.map(\.line.id))
      let gone = replaced.isEmpty ? "" : "，忘掉了 " + Self.numbers(replaced)
      return .ok("记下了 #\(index)\(line.pinned ? "，一直记着" : "")\(gone)。")
    case "recall":
      let query = try args.required("query")
      let found = try await store.recallCue(query)
      let words = CueStore.recallWords(query)
      var lines = found.lines.map { $0.line.shown(at: $0.index) + ($0.line.deletedAt == nil ? "" : "（已忘掉）") }
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
    case "schedules":
      let lines = try await store.cueScheduleLines()
      guard !lines.isEmpty else { return .ok("没有定时。") }
      let now = Date()
      var out: [String] = []
      for indexed in try await store.cueLines(lines.map(\.id)) {
        let line = indexed.line
        var parts = ["#\(indexed.index) \(line.text)", "下一次 \(line.remindAt.map { CueScheduleWords.time($0, now: now) } ?? "")"]
        parts.append(line.repeats.map(CueScheduleWords.repeats) ?? "一次")
        if let id = line.task, let card = try await store.card(id) { parts.append("挂在「\(card.heading)」（\(card.id.shortID)）") }
        out.append(parts.joined(separator: " · "))
      }
      return .ok(out.joined(separator: "\n"))
    case "zoom":
      guard let lo = args.int("lo") else { throw Failure("zoom 要给 lo（与 hi，同记忆视图里的 #lo-hi）") }
      guard let text = CueMemoryView(try await store.cueMemory()).zoom(lo: lo, hi: args.int("hi") ?? lo) else {
        throw Failure("展开不了 #\(lo)-\(args.int("hi") ?? lo)：照记忆视图或摘要里出现过的 #a-b 写，单行只给 lo")
      }
      return .ok(text)
    case let other: throw Failure("memory 没有 \(other)：可用 note / recall / zoom / forget / pin / remind / schedules")
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

  /// 整理记忆的大脑收口一直记着的：给 text 是把那几条（至少两条）并成一条一直记着的，任一是他的原话新行就算他的；不给是那几条不再一直记着
  /// （回到普通记忆，之后照常被摘要）。只认此刻还一直记着的行。
  func tidy(_ args: Args) async throws -> Result {
    let lines = try await lines(args, "lines")
    if let loose = lines.first(where: { !$0.line.pinned || $0.line.remindAt != nil }) {
      throw Failure("#\(loose.index) 不是一直记着的：只整理 <pinned> 里的行")
    }
    guard let text = args.string("text") else {
      for line in lines { try await store.pinCueLine(line.line.id, false) }
      return .ok("\(Self.numbers(lines)) 不再一直记着。")
    }
    guard lines.count >= 2 else { throw Failure("并成一条要给至少两条 lines；只想改写一条就别动它") }
    let source: CueLineSource = lines.contains { $0.line.source == .known(.you) } ? .you : .cue
    let (_, index) = try await store.noteCueLine(text, source: source, pinned: true, replacing: lines.map(\.line.id))
    return .ok("\(Self.numbers(lines)) 并成了 #\(index)。")
  }

  /// `line`：序号（可带 #）或 id。
  private func line(_ args: Args) async throws -> (CueMemoryLine, Int) {
    guard let raw = args.string("line") ?? args.int("line").map(String.init) else { throw Failure("要给 line（序号，如 12）") }
    let found = try await line(raw)
    return (found.line, found.index)
  }

  /// 一条记忆：序号（可带 #）或 id；忘掉了的也认（调用方看 `deletedAt`）。
  private func line(_ raw: String) async throws -> CueIndexedLine {
    let trimmed = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    if let index = Int(trimmed), let line = try await store.cueLine(at: index) { return CueIndexedLine(index: index, line: line) }
    if let uuid = UUID(uuidString: raw), let line = try await store.cueLine(uuid), let index = try await store.cueLineIndex(uuid) {
      return CueIndexedLine(index: index, line: line)
    }
    throw Failure("没有记忆 \(raw)：用 recall 找它的序号")
  }

  /// `key` 下的几条记忆（序号或 id 的数组），去重、按给的先后；忘掉了的退回。
  func lines(_ args: Args, _ key: String, allowEmpty: Bool = false) async throws -> [CueIndexedLine] {
    let refs = args.list(key)
    guard allowEmpty || !refs.isEmpty else { throw Failure("要给 \(key)：序号的数组，如 [3, 7]") }
    var found: [CueIndexedLine] = []
    for ref in refs {
      let hit = try await line(ref)
      guard hit.line.deletedAt == nil else { throw Failure("#\(hit.index) 已经忘掉了") }
      if !found.contains(where: { $0.line.id == hit.line.id }) { found.append(hit) }
    }
    return found
  }

  /// "#3、#7"
  static func numbers(_ lines: [CueIndexedLine]) -> String { lines.map { "#\($0.index)" }.joined(separator: "、") }

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

extension Args {
  /// 字符串或整数的数组（记忆的序号），统一成字符串；单个值当一个的数组。
  func list(_ key: String) -> [String] {
    let items = raw[key] as? [Any] ?? raw[key].map { [$0] } ?? []
    return items.compactMap { ($0 as? String) ?? ($0 as? NSNumber).map { "\($0.intValue)" } }
  }
}
