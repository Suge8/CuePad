import CueStore
import CueText
import Foundation

extension CueTools {
  func memory(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "note":
      let (line, index) = try await store.noteCueLine(try args.required("text"), source: .cue, pinned: args.bool("pin") ?? false)
      return .ok("记下了 #\(index)\(line.pinned ? "，一直记着" : "")。")
    case "recall":
      let found = try await store.recallCue(try args.required("query"))
      var lines = found.lines.map { "#\($0.index) \($0.line.text)" + ($0.line.deletedAt == nil ? "" : "（已忘掉）") }
      lines += found.messages.map { "对话 \(iso($0.createdAt)) \($0.author.rawValue)：\(CueEnvelope.clip(CueFormat.plainText($0.text), 160))" }
      lines += found.cards.map { "\($0.isTask ? "任务" : "灵感")「\($0.heading)」（\($0.id.shortID)）" }
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
      guard let lo = args.int("lo"), let hi = args.int("hi") else { throw Failure("merge 要给 lo 与 hi（区间 [lo, hi)）") }
      try await store.setCueSummary(lo: lo, hi: hi, text: try args.required("text"))
      return .ok("#\(lo)-\(hi - 1) 合成了一行。")
    case "renew":
      let handoff = try args.required("handoff")
      guard handoff.count <= Self.handoffLimit else {
        throw Failure("交接 \(handoff.count) 字，上限 \(Self.handoffLimit)，没写：只写推进中的事各自做到哪、下一步，和他之间没了结的事，每件一两句")
      }
      let message = try await store.addCueMessage(.handoff, text: handoff)
      return .ok("交接备忘写好了，接下来换新上下文。（\(message.id.shortID)）")
    case "allow": return try await allow(args)
    case let other: throw Failure("memory 没有 \(other)：可用 note / recall / forget / pin / remind / merge / renew / allow")
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
