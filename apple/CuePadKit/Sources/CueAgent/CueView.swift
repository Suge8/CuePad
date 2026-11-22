import CueStore
import CueText
import Foundation

public enum CueView {
  public static let budget = 5000
  public static let fetched = 1000
  static let hisLimit = 600
  static let yourLimit = 300
  static let roundLimit = 300

  public static func render(_ messages: [CueMessage]) -> String? {
    var kept: [Entry] = [], total = 0
    for message in messages.reversed() {
      guard let line = line(message, CueEnvelope.clip(CueFormat.plainText(message.text), Int.max)) else { continue }
      total += line.count
      guard total <= budget else { break }
      kept.append(Entry(at: message.createdAt, text: line))
    }
    guard !kept.isEmpty else { return nil }
    let calendar = Calendar(identifier: .gregorian)
    var lines = ["<view>", header], day: DateComponents?
    for (index, event) in kept.reversed().enumerated() {
      let today = calendar.dateComponents([.year, .month, .day], from: event.at)
      let date = today == day ? "" : event.at.formatted(CueEnvelope.monthDay) + " "
      day = today
      lines.append("#\(index + 1) \(date)\(event.at.formatted(CueEnvelope.clock)) \(event.text)")
    }
    lines.append("</view>")
    return lines.joined(separator: "\n")
  }

  static let header = "你和他最近的对话与你此前每一轮的经过（从早到晚，一条一行：#序号 时刻）。这只是最后一小段，更早的对话不在这里、往往比这多得多：他问起自己的事（说过的、做过的、有几次、一共多少、最近一次、他的情况与喜好），或要你推荐、出主意，先用 memory recall 查全再答；这里没有不等于没有。"

  private struct Entry {
    var at: Date
    var text: String
  }

  private static func line(_ message: CueMessage, _ text: String) -> String? {
    switch message.author.known {
    case .you: message.deliveredAt == nil ? nil : "他：" + text.clipped(hisLimit)
    case .cue: text.isEmpty ? nil : "你：" + text.clipped(yourLimit)
    case .note, .round: round(message.tools)
    case nil: nil
    }
  }

  private static func round(_ tools: ChatMessage.Tools?) -> String? {
    let steps = (tools?.items ?? []).filter { $0.kind != .said && $0.kind != .ask }.map { $0.target + ($0.failed ? "（没成）" : "") }
    guard !steps.isEmpty else { return nil }
    return ("你这一轮：" + steps.joined(separator: "；")).clipped(roundLimit)
  }
}
