import CueStore
import CueText
import Foundation

/// 新会话第一条输入里的对话视图（`CueKeeper`），在记忆视图之后、信封之前，接上此前的经过。从库里的对话现拼：他的话、你的回复与 tell、你的动态、
/// 每一轮的经过（那一行的清单，`CueStore.recordCueRound`），一条一行，带序号与绝对时刻，从早到晚；从最新的往前取到 `budget` 字。
/// 提问的回答另起一行，排在回答的时刻。换新之后的各轮照常留在会话里，下一次换新时再并进视图。
public enum CueView {
  /// 5000 字：换新那一刻实测 5000 字与 1.2 万字接得一样好，按真实时间线算每天便宜约 20%（冷了换新要整段重写起点，起点越小越省）。
  /// 换新后的起点约为固定前缀（系统提示与工具说明，约 1.1 万 token）加记忆视图（至多约 8k）与这份视图，约 2 万。最近十几轮来回与各轮的经过
  /// （一轮的经过一行至多 `roundLimit` 字）在这里，更早的靠记忆与 memory recall。
  public static let budget = 5000
  /// 从库里读最近这么多条对话来拼（一行至少十来个字，读这么多够填满预算）
  public static let fetched = 1000
  static let hisLimit = 600
  static let yourLimit = 300
  static let roundLimit = 300

  /// `messages` 是最近的对话（`CueStore.cueMessages`，从早到晚）；一行都没有为 nil。
  /// 先只按时刻排好每条可能的一行，再从最新的往前现拼正文、拼满预算就停：读进来的上千条里只有留下的那几十条去整理正文。
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
      let date = today == day ? "" : event.at.formatted(monthDay)
      day = today
      lines.append("#\(index + 1) \(date)\(event.at.formatted(CueEnvelope.clock)) \(event.text)")
    }
    lines.append("</view>")
    return lines.joined(separator: "\n")
  }

  static let header = "你和他最近的对话与你此前每一轮的经过（从早到晚，一条一行：#序号 时刻）。这只是最后一小段，更早的对话不在这里、往往比这多得多：他问起自己的事（说过的、做过的、有几次、一共多少、最近一次、他的情况与喜好），或要你推荐、出主意，先用 memory recall 查全再答；这里没有不等于没有。"

  /// 换了一天的那一行时刻前写的月日（同信封的时刻，按此刻的时区）：10-21
  private static var monthDay: Date.VerbatimFormatStyle {
    .init(format: "\(month: .twoDigits)-\(day: .twoDigits) ", timeZone: .current, calendar: Calendar(identifier: .gregorian))
  }

  private struct Entry {
    var at: Date
    var text: String
  }

  /// 一条对话可能占的一行（`answer`：提问的回答另起的那一行，排在回答的时刻），从早到晚；正文要不要、写成什么由 `line` 现定。
  private struct Slot {
    var at: Date
    var order: Int
    var answer = false
  }

  /// 他还没交给你的话不列（它们这次随信封交给你）；提问的回答交过了才列。
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

  /// 这一行的正文（`text` 是这条对话去掉图片、拍成一行的正文）；空的 Cue 消息与没做事的一轮没有这一行。
  private static func line(_ slot: Slot, _ message: CueMessage, _ text: String) -> String? {
    switch message.author.known {
    case .you:
      return "他：" + text.clipped(hisLimit)
    case .cue:
      guard !text.isEmpty else { return nil }
      if slot.answer { return "他在卡上选了「\(message.answer!)」：答「\(text.clipped(40))」" }
      return message.choices.map { "你问他：\(text.clipped(yourLimit))（选项：\($0.joined(separator: " / "))）" } ?? "你：" + text.clipped(yourLimit)
    case .note where !text.isEmpty:
      return "你的动态：" + text.clipped(yourLimit)
    case .note, .round:
      return round(message.tools)
    case nil:
      return nil
    }
  }

  /// 一轮的经过：清单里的每一步（对他说的话已是自己的一行，不重复），没成的标出。
  private static func round(_ tools: PiChatMessage.Tools?) -> String? {
    let steps = (tools?.items ?? []).filter { $0.message == nil }.map { $0.target + ($0.failed ? "（没成）" : "") }
    guard !steps.isEmpty else { return nil }
    return ("你这一轮：" + steps.joined(separator: "；")).clipped(roundLimit)
  }
}
