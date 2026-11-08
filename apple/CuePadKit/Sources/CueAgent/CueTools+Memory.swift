import CueStore
import CueText
import Foundation

extension CueTools {
  /// 命中的那一段，至多 `excerptLimit` 字：从某个命中词前面一点起，取含不同的命中词最多的一段，一样多取命中次数多的，再一样取靠前的。
  /// 不从开头截：长回复的开头多半不是要找的。不只认最少见的那个词：问的说法常与原文对不上（问"停止维护"，原文写"结束维护"），
  /// 只认一个词就落到别处（长程评测里查 Node 的建议，落到了 ESLint 那一行），几个词凑在一起的地方才是要找的。
  static func excerpt(_ text: String, around words: [String]) -> String {
    let flat = CueEnvelope.clip(text, Int.max)
    var hits: [(word: Int, at: Int, end: Int)] = []
    for (index, word) in words.enumerated() where !word.isEmpty {
      var from = flat.startIndex
      while let range = flat.range(of: word, options: .caseInsensitive, range: from..<flat.endIndex) {
        hits.append((index, flat.distance(from: flat.startIndex, to: range.lowerBound), flat.distance(from: flat.startIndex, to: range.upperBound)))
        from = range.upperBound
      }
    }
    func rank(_ start: Int) -> (Int, Int, Int) {
      let inside = hits.filter { $0.at >= start && $0.end < start + excerptLimit }
      return (Set(inside.map(\.word)).count, inside.count, -start)
    }
    guard let start = hits.map({ max(0, $0.at - excerptLead) }).max(by: { rank($0) < rank($1) }) else { return flat.clipped(excerptLimit) }
    return (start == 0 ? "" : "…") + String(flat.dropFirst(start)).clipped(excerptLimit)
  }

  static let excerptLimit = 200
  static let excerptLead = 40

  /// recall 查到的一条会话回复：哪个会话、什么时候、命中的那一段。
  func replyLine(_ reply: CueRecall.Reply, around words: [String]) -> String {
    let name = reply.session.map(CueEnvelope.sessionName) ?? "会话（\(reply.message.sessionID.prefix(8))）"
    return "\(name) \(iso(reply.message.at)) 回复：\(Self.excerpt(reply.message.text, around: words))"
  }

  func memory(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "note":
      let source: CueLineSource = args.bool("his") == true ? .you : .cue
      let replaced = try await lines(args, "replaces", allowEmpty: true)
      if let schedule = replaced.first(where: { $0.remindAt != nil }) {
        throw Failure("\(schedule.id.uuidString.lowercased()) 是定时，不能替换：改定时先 forget 它再 remind")
      }
      let pin = args.bool("pin") ?? replaced.contains { $0.pinned }
      let line = try await store.noteCueLine(
        try args.required("text"), source: source, pinned: pin, replacing: replaced.map(\.id))
      let gone = replaced.isEmpty ? "" : "，忘掉了 " + Self.identities(replaced)
      return .ok("记下了 \(line.id.uuidString.lowercased())\(line.pinned ? "，标为重点" : "")\(gone)。")
    case "recall":
      let query = try args.required("query")
      let found = try await store.recallCue(query)
      let words = CueStore.recallWords(query)
      var lines = found.lines.map { $0.shown() + ($0.deletedAt == nil ? "" : "（已忘掉）") }
      lines += found.messages.map { "对话 \(iso($0.createdAt)) \($0.author.rawValue)：\(Self.excerpt(CueFormat.plainText($0.text), around: words))" }
      lines += found.cards.map { "\($0.isTask ? "任务" : "灵感")「\($0.heading)」（\($0.id.shortID)）" }
      lines += found.replies.map { replyLine($0, around: words) }
      let more = found.unlisted
      let unlisted = [("记忆", more.lines), ("对话", more.messages), ("任务", more.cards), ("会话回复", more.replies)].filter { $0.1 > 0 }
      if !unlisted.isEmpty {
        lines.append("还有命中没列出：" + unlisted.map { "\($0.0) \($0.1) 条" }.joined(separator: "、") + "。要查全就加上更具体的词、换个说法再查。")
      }
      return .ok(lines.isEmpty ? "没找到。" : lines.joined(separator: "\n"))
    case "forget":
      let line = try await line(args)
      try await store.forgetCueLine(line.id)
      return .ok("忘掉了 \(line.id.uuidString.lowercased())。")
    case "pin":
      let line = try await line(args)
      guard let pinned = args.bool("pinned") else { throw Failure("pin 要给 pinned: true 或 false") }
      try await store.pinCueLine(line.id, pinned)
      return .ok(pinned ? "\(line.id.uuidString.lowercased()) 标为重点。" : "\(line.id.uuidString.lowercased()) 取消重点。")
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
      let task = try await args.string("task").asyncMap { try await self.references.task($0) }
      // 回收站里的 `task(_:)` 已不认；完成、归档的挂上去不会再被收掉（`endCueSchedules`）
      if let task, task.completedAt != nil || task.archivedAt != nil {
        throw Failure("「\(task.heading)」已完成或已归档：定时只挂在没完成的任务上")
      }
      let line = try await store.noteCueLine(try args.required("text"), source: .cue, remindAt: at, repeats: repeats, task: task?.id)
      let kind = line.repeats.map(CueScheduleWords.repeats) ?? "一次"
      return .ok("定好了 \(line.id.uuidString.lowercased())（\(kind)\(task.map { "，挂在「\($0.heading)」上" } ?? "")），\(iso(at)) 第一次叫醒你；不再定时就 forget 它。")
    case "schedules":
      let lines = try await store.cueScheduleLines()
      guard !lines.isEmpty else { return .ok("没有定时。") }
      let now = Date()
      var out: [String] = []
      for line in lines {
        var parts = ["\(line.id.uuidString.lowercased()) \(line.text)", "下一次 \(line.remindAt.map { CueScheduleWords.time($0, now: now) } ?? "")"]
        parts.append(line.repeats.map(CueScheduleWords.repeats) ?? "一次")
        if let id = line.task, let card = try await store.card(id) { parts.append("挂在「\(card.heading)」（\(card.id.shortID)）") }
        out.append(parts.joined(separator: " · "))
      }
      return .ok(out.joined(separator: "\n"))
    case "zoom":
      guard args.raw["lo"] == nil, args.raw["hi"] == nil else { throw Failure("zoom 用 line 的 UUID 或原样的 range；不再接受位置编号") }
      if args.raw["line"] != nil {
        guard args.raw["range"] == nil else { throw Failure("zoom 只给 line 或 range 其中一个") }
        let line = try await line(args)
        return .ok(line.shown() + (line.deletedAt == nil ? "" : "（已忘掉）"))
      }
      let view = CueMemoryView(try await store.cueMemory())
      if args.raw["range"] != nil { return .ok(try view.zoom(range: Self.range(args))) }
      return .ok("重点：\n\(view.pinnedText)\n\n\(view.viewText ?? "其余记忆：没有。")")
    case let other: throw Failure("memory 没有 \(other)：可用 note / recall / zoom / forget / pin / remind / schedules")
    }
  }

  /// range 来自生成摘要的同一份输入；存储层在事务内核对输入，不重新给旧文本绑定当前指纹。
  func merge(_ args: Args) async throws -> Result {
    let range = try Self.range(args)
    try await store.setCueSummary(range: range, text: try args.required("text"))
    let view = CueMemoryView(try await store.cueMemory())
    let parents = view.merges.filter { $0.range.lo <= range.lo && $0.range.hi >= range.hi && $0.range != range }
    let next = parents.map { "\($0.range.label) range=\($0.range.reference)\n\($0.source)" }.joined(separator: "\n\n")
    return .ok("\(range.label) 合成了一行。" + (next.isEmpty ? "" : "\n<merge>\n\(next)\n</merge>"))
  }

  private static func range(_ args: Args) throws -> CueMemoryRange {
    guard let raw = args.string("range"), let range = CueMemoryRange(reference: raw) else {
      throw Failure("range 要原样复制输入块头的范围引用")
    }
    return range
  }

  private func line(_ args: Args) async throws -> CueMemoryLine {
    try await line(args.required("line"))
  }

  private func line(_ raw: String) async throws -> CueMemoryLine {
    guard let uuid = UUID(uuidString: raw) else { throw Failure("记忆用完整 UUID，不接受编号；用 recall 找到它") }
    guard let line = try await store.cueLine(uuid) else { throw Failure("没有记忆 \(raw)：用 recall 找到它") }
    return line
  }

  /// UUID 数组，去重并保持给定顺序；拒绝整数与已忘掉的记忆。
  private func lines(_ args: Args, _ key: String, allowEmpty: Bool = false) async throws -> [CueMemoryLine] {
    guard args.raw[key] != nil else {
      if allowEmpty { return [] }
      throw Failure("要给 \(key)：UUID 字符串数组")
    }
    guard let refs = args.strings(key) else { throw Failure("\(key) 要给 UUID 字符串数组") }
    var found: [CueMemoryLine] = []
    for ref in refs {
      let hit = try await line(ref)
      guard hit.deletedAt == nil else { throw Failure("\(hit.id.uuidString.lowercased()) 已经忘掉了") }
      if !found.contains(where: { $0.id == hit.id }) { found.append(hit) }
    }
    return found
  }

  static func identities(_ lines: [CueMemoryLine]) -> String { lines.map { $0.id.uuidString.lowercased() }.joined(separator: "、") }

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
