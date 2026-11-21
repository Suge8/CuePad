import CueStore
import Foundation
import NaturalLanguage

extension CueTools {
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

  static let questionLimit = 120
  static let relatedLimit = 2
  static let relatedCap = 4

  static func words(in text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }.filter { $0.count >= 2 }
  }
}
