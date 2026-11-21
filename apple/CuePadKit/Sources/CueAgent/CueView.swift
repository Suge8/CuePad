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
    var plain: [Int: String] = [:]
    var kept: [Entry] = [], total = 0
    for slot in slots(messages).reversed() {
      let message = messages[slot.order]
      let text = plain[slot.order] ?? CueEnvelope.clip(CueFormat.plainText(message.text), Int.max)
      plain[slot.order] = text
      guard let line = line(slot, message, text) else { continue }
      total += line.count
      guard total <= budget else { break }
      kept.append(Entry(at: slot.at, text: line))
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

  private struct Slot {
    var at: Date
    var order: Int
    var answer = false
  }

  private static func slots(_ messages: [CueMessage]) -> [Slot] {
    var slots: [Slot] = []
    for (order, message) in messages.enumerated() {
      switch message.author.known {
      case .you:
        if message.deliveredAt != nil { slots.append(Slot(at: message.createdAt, order: order)) }
      case .cue:
        slots.append(Slot(at: message.createdAt, order: order))
        if message.answer != nil, let answeredAt = message.answeredAt, let delivered = message.deliveredAt, delivered >= answeredAt {
          slots.append(Slot(at: answeredAt, order: order, answer: true))
        }
      case .note, .round:
        slots.append(Slot(at: message.createdAt, order: order))
      case nil:
        continue
      }
    }
    return slots.sorted { ($0.at, $0.order, $0.answer ? 1 : 0) < ($1.at, $1.order, $1.answer ? 1 : 0) }
  }

  private static func line(_ slot: Slot, _ message: CueMessage, _ text: String) -> String? {
    switch message.author.known {
    case .you:
      return "他：" + text.clipped(hisLimit)
    case .cue:
      guard !text.isEmpty else { return nil }
      if slot.answer { return "他在卡上选了「\(message.answer!)」：答「\(text.clipped(40))」" }
      return message.choices.map { "你问他：\(text.clipped(yourLimit))（选项：\($0.joined(separator: " / "))）" } ?? "你：" + text.clipped(yourLimit)
    case .note, .round:
      return round(message.tools)
    case nil:
      return nil
    }
  }

  private static func round(_ tools: ChatMessage.Tools?) -> String? {
    let steps = (tools?.items ?? []).filter { $0.kind != .said && $0.kind != .ask }.map { $0.target + ($0.failed ? "（没成）" : "") }
    guard !steps.isEmpty else { return nil }
    return ("你这一轮：" + steps.joined(separator: "；")).clipped(roundLimit)
  }
}
