import CueStore
import CueText
import Foundation

/// 原型（`CueFresh`）：每次醒来交给大脑的对话视图，放在信封前面。从库里的对话现拼：他的话、你的回复与 tell、你的动态、
/// 每一轮的经过（那一行的清单，`CueStore.recordCueRound`），一条一行，带序号与时刻，从早到晚。
/// 提示缓存的前缀靠它只在末尾增长：视图从 `from`（管理器记着）起，越早的行在相邻两次醒来之间不变——时刻写绝对的，
/// 行里不写之后会变的（提问的回答另起一行，排在回答的时刻）；超过 `budget` 字就从前面丢到一半，新的 `from` 是留下的第一行的时刻，
/// 前缀只在这时变一次，而不是每次醒来都滑一点。
public enum CueView {
  /// 约 2.4 万字：中文一字约一个 token，加上系统提示与工具说明约一万、信封几千，每次醒来的输入至多四万上下，
  /// 低于现做法的换新线（`CueContext.renewAt`，6 万）；丢到一半后视图在 1.2–2.4 万字之间，
  /// 够放几十轮来回与各轮的经过（一轮的经过一行至多 `roundLimit` 字）。
  public static let budget = 24_000
  /// 从库里读最近这么多条对话来拼（一行至少十来个字，读这么多够填满预算）
  public static let fetched = 1000
  static let hisLimit = 600
  static let yourLimit = 300
  static let roundLimit = 300

  public struct Rendered: Sendable {
    /// 视图（`<view>` 块）；一行都没有为 nil
    public var text: String?
    /// 下次从哪起
    public var from: Date?
  }

  /// `messages` 是最近的对话（`CueStore.cueMessages`，从早到晚）。
  public static func render(_ messages: [CueMessage], from: Date?) -> Rendered {
    var events = entries(messages).filter { from == nil || $0.at >= from! }
    var total = events.reduce(0) { $0 + $1.text.count }
    if total > budget {
      while total > budget / 2, !events.isEmpty { total -= events.removeFirst().text.count }
    }
    guard let first = events.first else { return Rendered(text: nil, from: from) }
    let calendar = Calendar(identifier: .gregorian)
    var lines = ["<view>", header], day: DateComponents?
    for (index, event) in events.enumerated() {
      let today = calendar.dateComponents([.year, .month, .day], from: event.at)
      let date = today == day ? "" : "\(CueEnvelope.pad(today.month!))-\(CueEnvelope.pad(today.day!)) "
      day = today
      lines.append("#\(index + 1) \(date)\(CueEnvelope.clock(event.at, calendar)) \(event.text)")
    }
    lines.append("</view>")
    return Rendered(text: lines.joined(separator: "\n"), from: first.at)
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
      case .handoff, nil:
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
