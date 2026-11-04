import CueStore
import Foundation
import NaturalLanguage

extension CueTools {
  /// 他交出去的几句里每句短问句，按它的词在你管过的会话回复里查到的（同 memory recall 会话回复那一类的排法与截段），按句子先后合并去重，至多 `relatedLimit` 条，
  /// 随信封或插给在跑那一轮的话带上（`CueEnvelope.related`）。一句一句判、一句一句查：几句拼在一起时长交代把整段撑过 `questionLimit`，里面的问句就查不到。
  /// 会话交回过的细节换新后只在会话回复里：Cue 常不查就凭常识答（长程评测问"依赖清单里建议 Node 升到几"，不查的那几遍答成常识里的 24，
  /// 提示词里写明先 recall 也只查了八遍里的五遍）。只查会话回复：记忆与对话已在视图里。只查短问句：贴来的长文、交代的事不是在问以前的事，查了是噪声。
  /// 中文词之间没有空格，先切成词再查（recall 按空格分词）。
  public func related(to said: [String]) async throws -> [String] {
    var found: [String] = []
    for text in said.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where found.count < Self.relatedLimit {
      guard text.count <= Self.questionLimit, text.contains(where: { "？?".contains($0) }) else { continue }
      let words = Self.words(in: text)
      for reply in try await store.recallCueReplies(words.joined(separator: " "), limit: Self.relatedLimit) {
        let line = replyLine(reply, around: words)
        if found.count < Self.relatedLimit, !found.contains(line) { found.append(line) }
      }
    }
    return found
  }

  /// 算短问句的上限（字）
  static let questionLimit = 120
  /// 带上的会话回复至多几条
  static let relatedLimit = 2

  /// 一句话里两个字以上的词（单字多是虚词，查了只是噪声）。
  static func words(in text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }.filter { $0.count >= 2 }
  }
}
