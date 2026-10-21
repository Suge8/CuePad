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
  public static func render(_ messages: [CueMessage]) -> String? {
    var kept: [Entry] = [], total = 0
    for entry in entries(messages).reversed() {
      total += entry.text.count
      guard total <= budget else { break }
      kept.append(entry)
    }
    guard !kept.isEmpty else { return nil }
    let calendar = Calendar(identifier: .gregorian)
    var lines = ["<view>", header], day: DateComponents?
    for (index, event) in kept.reversed().enumerated() {
      let today = calendar.dateComponents([.year, .month, .day], from: event.at)
      let date = today == day ? "" : "\(CueEnvelope.pad(today.month!))-\(CueEnvelope.pad(today.day!)) "
      day = today
      lines.append("#\(index + 1) \(date)\(CueEnvelope.clock(event.at, calendar)) \(event.text)")
    }
    lines.append("</view>")
    return lines.joined(separator: "\n")
  }

  static let header = "你和他的对话与你此前每一轮的经过（从早到晚，一条一行：#序号 时刻；更早的不在这里，要细节用 memory recall 查）："

  private struct Entry {
    var at: Date
    var text: String
  }

  /// 每条对话一行（他还没交给你的话不列：它们这次随信封交给你），提问的回答另起一行。
  private static func entries(_ messages: [CueMessage]) -> [Entry] {
    var entries: [(entry: Entry, order: Int)] = []
    for (order, message) in messages.enumerated() {
      let text = CueEnvelope.clip(CueFormat.plainText(message.text), Int.max)
      switch message.author.known {
      case .you:
        guard message.deliveredAt != nil else { continue }
        entries.append((Entry(at: message.createdAt, text: "他：" + text.clipped(hisLimit)), order))
      case .cue:
        guard !text.isEmpty else { continue }
        let line = message.choices.map { "你问他：\(text.clipped(yourLimit))（选项：\($0.joined(separator: " / "))）" } ?? "你：" + text.clipped(yourLimit)
        entries.append((Entry(at: message.createdAt, text: line), order))
        if let answer = message.answer, let answeredAt = message.answeredAt, let delivered = message.deliveredAt, delivered >= answeredAt {
          entries.append((Entry(at: answeredAt, text: "他在卡上选了「\(answer)」：答「\(text.clipped(40))」"), order))
        }
      case .note where !text.isEmpty:
        entries.append((Entry(at: message.createdAt, text: "你的动态：" + text.clipped(yourLimit)), order))
      case .note, .round:
        guard let round = round(message.tools) else { continue }
        entries.append((Entry(at: message.createdAt, text: round), order))
      case nil:
        continue
      }
    }
    return entries.sorted { ($0.entry.at, $0.order) < ($1.entry.at, $1.order) }.map(\.entry)
  }

  /// 一轮的经过：清单里的每一步（对他说的话已是自己的一行，不重复），没成的标出。
  private static func round(_ tools: PiChatMessage.Tools?) -> String? {
    let steps = (tools?.items ?? []).filter { $0.message == nil }.map { $0.target + ($0.failed ? "（没成）" : "") }
    guard !steps.isEmpty else { return nil }
    return ("你这一轮：" + steps.joined(separator: "；")).clipped(roundLimit)
  }
}
