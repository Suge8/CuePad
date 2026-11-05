import CueStore
import Foundation
import NaturalLanguage

extension CueTools {
  /// 他交出去的几句里的短问句（`question(in:)`），各按它的词在你管过的会话回复里查（同 memory recall 会话回复那一类的排法与截段），
  /// 随信封或插给在跑那一轮的话带上（`CueEnvelope.related`）。先给每句它查到的第一条，再按句子先后补满：一句查到的几条不占满别的问句的名额。
  /// 合起来至多 `relatedLimit` 条，问句更多时每句一条、至多 `relatedCap` 条。一句一句判、一句一句查：几句拼在一起，长交代把整段撑过 `questionLimit`，
  /// 里面的问句就查不到。
  public func related(to said: [String]) async throws -> [String] {
    var found: [[String]] = []
    for question in said.compactMap(Self.question(in:)) {
      let words = Self.words(in: question)
      found.append(try await store.recallCueReplies(words.joined(separator: " "), limit: Self.relatedLimit).map { replyLine($0, around: words) })
    }
    let room = min(max(Self.relatedLimit, found.count), Self.relatedCap)
    var picked: [String] = []
    for rank in 0..<Self.relatedLimit {
      for lines in found where rank < lines.count && picked.count < room && !picked.contains(lines[rank]) { picked.append(lines[rank]) }
    }
    return picked
  }

  /// 这句话里要查的问句：整条是短问句就是整条；长的（贴来的长文、一段交代）只看最后一句，它是短问句、不在引号里才算——
  /// 他自己问的放在交代后面，贴来的内容里的问句落在中间（长程评测贴的客服反馈里 9 个问句都在中间），最前面的问句因此不查。没有为 nil。
  static func question(in said: String) -> String? {
    func asks(_ text: String) -> Bool { text.count <= questionLimit && text.contains(where: { "？?".contains($0) }) }
    let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
    if asks(text) { return text }
    let own = text.replacing(/“[^”]*”|「[^」]*」|"[^"]*"/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard own.hasSuffix("？") || own.hasSuffix("?") else { return nil }
    let body = own.dropLast(), start = body.lastIndex { "。！？!?\n".contains($0) }.map { body.index(after: $0) } ?? body.startIndex
    let last = own[start...].trimmingCharacters(in: .whitespacesAndNewlines)
    return asks(last) ? last : nil
  }

  /// 算短问句的上限（字）
  static let questionLimit = 120
  /// 带上的会话回复一般至多几条（每句问句也至多查这么多条）
  static let relatedLimit = 2
  /// 问句多时每句一条，至多这么多条：一条连会话名约三百字，四条一千来字，是信封里近况预算（`recapBudget`）的一成；一次问四件以上很少见
  static let relatedCap = 4

  /// 一句话里两个字以上的词（单字多是虚词，查了只是噪声）。
  static func words(in text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }.filter { $0.count >= 2 }
  }
}
