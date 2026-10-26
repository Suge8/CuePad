import Foundation

/// 定时怎么重复（`CueMemoryLine.repeats`）：每天、每周几、每月几号，在一天里的某个时刻；一次性的定时没有它，只有 `remindAt`。
/// 存成 RFC 5545 RRULE 的子集（`rule`，如 `FREQ=WEEKLY;BYDAY=MO,TH;BYHOUR=9;BYMINUTE=0`）：Cue 的 memory remind 收的也是这一种写法，
/// 时刻缺省取第一次的那个时刻。读不出的写法（别的版本写的）当作不重复。
public struct CueRepeat: Hashable, Sendable {
  public enum Cycle: Hashable, Sendable {
    case daily
    /// 一周里的哪几天（`Calendar` 的 weekday：1 是周日）
    case weekly(Set<Int>)
    /// 每月几号（1–31）：没有这一号的月份跳过（同 RRULE）
    case monthly(Int)
  }

  public var cycle: Cycle
  public var hour: Int
  public var minute: Int

  /// 日子与时刻都在范围里才建得成（星期 1–7 且至少一天、几号 1–31、时 0–23、分 0–59）：读 RRULE 也经它，建成的都写得出 `rule`。
  public init?(_ cycle: Cycle, hour: Int, minute: Int) {
    let days =
      switch cycle {
      case .daily: true
      case .weekly(let days): !days.isEmpty && days.allSatisfy((1...7).contains)
      case .monthly(let day): (1...31).contains(day)
      }
    guard days, (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
    self.cycle = cycle
    self.hour = hour
    self.minute = minute
  }

  /// RRULE 的星期写法，下标 + 1 是 `Calendar` 的 weekday
  private static let days = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

  /// 每种频率认的字段：别的（INTERVAL、COUNT、UNTIL……）照不了它的意思，整条不认，不悄悄丢掉
  private static let fields: [String: Set<String>] = [
    "DAILY": ["FREQ", "BYHOUR", "BYMINUTE"], "WEEKLY": ["FREQ", "BYDAY", "BYHOUR", "BYMINUTE"],
    "MONTHLY": ["FREQ", "BYMONTHDAY", "BYHOUR", "BYMINUTE"],
  ]

  /// 读 RRULE 子集；没写 BYHOUR、BYMINUTE 时取 `time` 在 `calendar` 里的时刻。写法不在子集里（多出别的字段也算）为 nil。
  public init?(rule: String, time: Date? = nil, calendar: Calendar = .current) {
    var parts: [String: String] = [:]
    for part in rule.uppercased().replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
      let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard pair.count == 2, parts[pair[0]] == nil else { return nil }
      parts[pair[0]] = pair[1]
    }
    guard let allowed = parts["FREQ"].flatMap({ Self.fields[$0] }), Set(parts.keys).isSubset(of: allowed) else { return nil }
    let clock = time.map { calendar.dateComponents([.hour, .minute], from: $0) }
    guard let hour = parts["BYHOUR"].flatMap({ Int($0) }) ?? clock?.hour, let minute = parts["BYMINUTE"].flatMap({ Int($0) }) ?? clock?.minute
    else { return nil }
    let cycle: Cycle
    switch parts["FREQ"] {
    case "DAILY": cycle = .daily
    case "WEEKLY":
      let named = parts["BYDAY"]?.split(separator: ",").map { Self.days.firstIndex(of: String($0)).map { $0 + 1 } }
      guard let days = named ?? time.map({ [calendar.component(.weekday, from: $0)] }), !days.contains(nil) else { return nil }
      cycle = .weekly(Set(days.compactMap { $0 }))
    case "MONTHLY":
      guard let day = parts["BYMONTHDAY"].flatMap({ Int($0) }) ?? time.map({ calendar.component(.day, from: $0) }) else { return nil }
      cycle = .monthly(day)
    default: return nil
    }
    self.init(cycle, hour: hour, minute: minute)
  }

  public var rule: String {
    let frequency: String =
      switch cycle {
      case .daily: "FREQ=DAILY"
      case .weekly(let days): "FREQ=WEEKLY;BYDAY=" + days.sorted().map { Self.days[$0 - 1] }.joined(separator: ",")
      case .monthly(let day): "FREQ=MONTHLY;BYMONTHDAY=\(day)"
      }
    return frequency + ";BYHOUR=\(hour);BYMINUTE=\(minute)"
  }

  /// 不晚于 `now` 的最近一次（从 `due` 起往后数；`due` 本身晚于 `now` 时就是它）：错过了几次，只补这最近的一次。
  public func latest(from due: Date, until now: Date, calendar: Calendar = .current) -> Date {
    var (latest, next) = (due, self.next(after: due, calendar: calendar))
    while next <= now { (latest, next) = (next, self.next(after: next, calendar: calendar)) }
    return latest
  }

  /// `date` 之后的下一次。到点之后按它往后推：中间错过的几次合成这一次之后的下一次。
  public func next(after date: Date, calendar: Calendar = .current) -> Date {
    // 每月几号要逐字匹配（没有 31 号的月份跳过）；时刻落在夏令时跳过的那一段时取之后最近的时刻
    let (matches, policy): ([DateComponents], Calendar.MatchingPolicy) =
      switch cycle {
      case .daily: ([DateComponents(hour: hour, minute: minute, second: 0)], .nextTime)
      case .weekly(let days): (days.map { DateComponents(hour: hour, minute: minute, second: 0, weekday: $0) }, .nextTime)
      case .monthly(let day): ([DateComponents(day: day, hour: hour, minute: minute, second: 0)], .strict)
      }
    return matches.compactMap { calendar.nextDate(after: date, matching: $0, matchingPolicy: policy) }.min() ?? .distantFuture
  }
}
