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
      guard at > Date() else { throw Failure("提醒时刻已经过了：\(raw)") }
      let (_, index) = try await store.noteCueLine(try args.required("text"), source: .cue, remindAt: at)
      return .ok("记下了 #\(index)，\(iso(at)) 叫醒你。")
    case "merge":
      guard let lo = args.int("lo"), let hi = args.int("hi") else { throw Failure("merge 要给 lo 与 hi（同待合并里的 #lo-hi，hi 含在内）") }
      try await store.setCueSummary(lo: lo, hi: hi + 1, text: try args.required("text"))
      return .ok("#\(lo)-\(hi) 合成了一行。")
    case "zoom":
      guard let lo = args.int("lo") else { throw Failure("zoom 要给 lo（与 hi，同记忆视图里的 #lo-hi）") }
      guard let text = CueMemoryView(try await store.cueMemory()).zoom(lo: lo, hi: args.int("hi") ?? lo) else {
        throw Failure("展开不了 #\(lo)-\(args.int("hi") ?? lo)：照记忆视图或摘要里出现过的 #a-b 写，单行只给 lo")
      }
      return .ok(text)
    case "allow": return try await allow(args)
    case let other: throw Failure("memory 没有 \(other)：可用 note / recall / zoom / forget / pin / remind / merge / allow")
    }
  }

  /// 改允许清单（`CueStore.setCueAllow`）：这类事在一个项目或所有项目里以后不用问，或去掉。
  private func allow(_ args: Args) async throws -> Result {
    let raw = try args.required("ask")
    guard let ask = CueAsk(rawValue: raw), ask.always != nil else { throw Failure("ask 只能是 \(Self.allowable)：规矩那一类不能放行") }
    let project = try await args.string("project").asyncMap(project)
    let allowed = args.bool("allowed") ?? true
    let changed = try await store.setCueAllow(CueAllow(ask, project: project?.id), allowed: allowed)
    let scope = project.map { "项目「\($0.name)」里" } ?? "所有项目里"
    let what = "\(scope)\(ask.name)" + (allowed ? "以后不用问" : "又要先问")
    return .ok((changed ? "记下了：" : "本来就是：") + what + "。")
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
