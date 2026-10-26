import CueStore
import Foundation

/// 定时写给 Cue 看的样子（信封与 memory 工具的结果，中文、不随界面语言）：界面上的说法在 App（`ScheduleText`）。
enum CueScheduleWords {
  /// "每天 8:00""每周一、四 9:00""每月 1 号 9:00"
  static func repeats(_ rule: CueRepeat) -> String {
    let clock = String(format: "%d:%02d", rule.hour, rule.minute)
    switch rule.cycle {
    case .daily: return "每天 \(clock)"
    case .weekly(let days):
      // 周一在前、周日在后
      let names = days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { ["日", "一", "二", "三", "四", "五", "六"][$0 - 1] }
      return "每周\(names.joined(separator: "、")) \(clock)"
    case .monthly(let day): return "每月 \(day) 号 \(clock)"
    }
  }

  /// 某个时刻：今天的只写时刻，别的天带上日期（"10-26 9:00"）。
  static func time(_ date: Date, now: Date) -> String {
    let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
    let clock = String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    guard !Calendar.current.isDate(date, inSameDayAs: now) else { return clock }
    return String(format: "%02d-%02d ", parts.month ?? 0, parts.day ?? 0) + clock
  }
}
