import CueStore
import Foundation

/// 写给 Cue 看的样子（信封与 `setup look`），中文、不随界面语言；界面上的说法在 App 的 `QuotaMeter`。
/// 吃紧（`tight`）的规则只在这里。读不到（查询失败、不报额度）不算吃紧：那是没有证据，不是用得多；常年查询失败的账号若算吃紧，信封每一轮都写它，Cue 照系统提示就一直绕开能用的那家。
/// 账号里有的窗口过了重置时间（`AccountQuota.reading` 整个算 `.expired`）时，没重置的窗口照常读（`live`）：5 小时窗口刚重置、本周已用到九成的账号照样吃紧。
enum CueQuotaWords {
  static let tightUse = 0.8

  static func tight(_ quota: AccountQuota, at now: Date) -> Bool {
    guard let live = live(quota, at: now) else { return false }
    if let binding = live.binding(at: now), binding.used(at: now) >= tightUse { return true }
    return live.windows.contains { $0.exhaustion(at: now) != nil }
  }

  static func account(_ quota: AccountQuota) -> String {
    let name = quota.account?.name ?? quota.account?.route
    return quota.provider + (name.map { "「\($0)」" } ?? "")
  }

  static func tightLine(_ quota: AccountQuota, at now: Date) -> String? {
    guard tight(quota, at: now), let live = live(quota, at: now) else { return nil }
    let binding = live.binding(at: now)
    let shown = live.windows.filter { $0 == binding || $0.exhaustion(at: now) != nil }
    return "\(account(quota)) " + shown.map { window(live, $0, at: now) }.joined(separator: "；")
  }

  static func line(_ quota: AccountQuota, at now: Date) -> String {
    let mark = tight(quota, at: now) ? "（吃紧）" : ""
    guard let live = live(quota, at: now) else { return "\(account(quota))\(mark) \(status(quota, at: now))" }
    let windows = quota.windows.map { now < $0.resetsAt ? window(live, $0, at: now) : "\(name($0)) 已过重置时间，等新的观测" }
    return "\(account(quota))\(mark) " + windows.joined(separator: "；")
  }

  /// 带上重置时刻：额度用完时 Cue 只看 `setup look agents` 一次，换不了模型就照它定时接着做。
  static func binding(_ quota: AccountQuota, model: ModelKey, at now: Date) -> String {
    guard let window = live(quota, at: now)?.binding(at: now, model: model.id) else { return "\(account(quota)) \(status(quota, at: now))" }
    return "\(account(quota)) \(name(window)) 已用 \(percent(window, at: now))，\(CueScheduleWords.time(window.resetsAt, now: now)) 重置"
  }

  /// 读法、卡着的规则仍是 `AccountQuota` 的；读不到或窗口全过了重置时间为 nil。
  private static func live(_ quota: AccountQuota, at now: Date) -> AccountQuota? {
    guard [.observed, .expired].contains(quota.reading(at: now)) else { return nil }
    var live = quota
    live.windows = quota.windows.filter { now < $0.resetsAt }
    return live.windows.isEmpty ? nil : live
  }

  private static func window(_ quota: AccountQuota, _ window: QuotaWindow, at now: Date) -> String {
    var parts = ["\(name(window)) 已用 \(percent(window, at: now))", "\(CueScheduleWords.time(window.resetsAt, now: now)) 重置"]
    if window == quota.binding(at: now) { parts.append("卡着") }
    if let out = window.exhaustion(at: now) { parts.append("照速度 \(CueScheduleWords.time(out, now: now)) 用完") }
    return parts.joined(separator: "，")
  }

  private static func percent(_ window: QuotaWindow, at now: Date) -> String { "\(Int((window.used(at: now) * 100).rounded()))%" }

  private static func name(_ window: QuotaWindow) -> String {
    let span =
      switch window.seconds {
      case QuotaWindow.week: "本周"
      case let s where s % 86_400 == 0: "\(s / 86_400) 天"
      default: "\(Int((Double(window.seconds) / 3_600).rounded())) 小时"
      }
    return [window.model, span].compactMap(\.self).joined(separator: " ")
  }

  private static func status(_ quota: AccountQuota, at now: Date) -> String {
    switch quota.reading(at: now) {
    case .observed: "读得到"
    case .failed: "读不到额度（查询失败）"
    case .unobserved: "还没观测到额度"
    case .unsupported: "这个授权不报额度"
    case .expired: "已过重置时间，等新的观测"
    }
  }
}
