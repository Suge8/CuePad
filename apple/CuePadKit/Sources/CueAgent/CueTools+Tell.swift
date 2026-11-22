import CueStore
import CueText
import Foundation

extension CueTools {
  func tell(_ args: Args) async throws -> Result {
    let related = try await args.string("task").asyncMap(references.task)
    let shots = try CueShot.checked(try await shots(args.raw["show"]))
    let ask = try args.string("ask").map { raw -> CueAsking in
      guard let ask = CueAsk(rawValue: raw), CueAsk.byCue.contains(ask) else { throw Failure("ask 只能是这几类：\(CuePrompt.asks)；别的事你自己定，做完告诉他") }
      return try CueAsking(ask, action: args.string("doing"), rule: args.string("rule"))
    }
    if ask == nil, !shots.isEmpty { throw Failure("show 只跟着 ask：要他看的图放在提问上") }
    var done: [String] = []
    if let ref = args.string("withdraw") {
      if ask == nil, args.string("restore") == nil, let aside = try Self.question(ref, in: await store.cueQuestionsSetAside()) {
        return .ok("「\(CueEnvelope.clip(CueFormat.plainText(aside.text), 40))」他开口时已收起，不在等你里，不用撤回" + (args.string("text") == nil ? "。" : "，text 也没发。"))
      } else {
        let question = try Self.question(ref, in: await store.cueMessagesWaitingForYou(), missing: "等你里没有 \(ref)：他可能已经答了，看信封里的等你")
        try await store.endCueQuestion(question.id, .withdrawn)
        done.append("已撤回「\(CueEnvelope.clip(CueFormat.plainText(question.text), 40))」。")
      }
    }
    if let ref = args.string("restore") {
      let question = try Self.question(ref, in: await store.cueQuestionsSetAside(), missing: "他开口收起的里没有 \(ref)：照他那句话后面列的 id 写")
      try await store.restoreCueQuestion(question.id)
      done.append("已放回「\(CueEnvelope.clip(CueFormat.plainText(question.text), 40))」。")
    }
    guard let text = args.string("text") else {
      guard !done.isEmpty else { throw Failure("要给 text（说什么）、withdraw（撤回哪条提问）或 restore（放回哪条）") }
      return .ok(done.joined())
    }
    let message = try await store.addCueMessage(.cue, text: text, ask: ask, shots: shots, urgent: args.bool("urgent") ?? false, task: related?.id, answeredRequests: nil)
    return .ok(done.joined() + (message.choices != nil ? "已问用户，等他选。" : "已告诉用户。") + "（\(message.id.shortID)）\n\(CueToolReceipt(.reply, message.id).mark)")
  }

  func shots(_ raw: Any?) async throws -> [CueShot] {
    guard let raw else { return [] }
    guard let items = raw as? [[String: Any]] else { throw Failure("show 是数组：[{file, look}]") }
    var shots: [CueShot] = []
    for item in items {
      let key = (item["file"] as? String ?? "").trimmingCharacters(in: .whitespaces)
      let hits = key.isEmpty ? [] : try await store.previews(idPrefix: key)
      guard hits.count == 1 else {
        throw Failure(hits.isEmpty ? "发到手机的里没有 \(key)：照 task peek 里列的 id 写" : "前缀 \(key) 对上了 \(hits.count) 份：多写几位")
      }
      shots.append(CueShot(preview: hits[0].id, look: item["look"] as? String ?? ""))
    }
    return shots
  }

  private static func question(_ ref: String, in candidates: [CueMessage], missing: String) throws -> CueMessage {
    guard let question = try question(ref, in: candidates) else { throw Failure(missing) }
    return question
  }

  private static func question(_ ref: String, in candidates: [CueMessage]) throws -> CueMessage? {
    let key = ref.trimmingCharacters(in: .whitespaces).lowercased()
    guard !key.isEmpty else { return nil }
    let hits = candidates.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
    if hits.count > 1 { throw Failure("前缀 \(ref) 对上了 \(hits.count) 条：多写几位") }
    return hits.first
  }
}
