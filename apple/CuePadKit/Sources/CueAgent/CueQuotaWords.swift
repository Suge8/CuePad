import CueStore
import Foundation

/// 额度写给 Cue 看的样子（信封与 `setup look`，中文、不随界面语言；界面上的说法在 App 的 `QuotaMeter`）。
/// 吃紧（`tight`）的规则只在这里：信封只写吃紧的账号，look 给吃紧的标出来。
enum CueQuotaWords {
  /// 卡着的窗口用到这么多算吃紧。
  static let tightUse = 0.8

  /// 吃紧：读不到（查询失败），卡着的窗口用到 `tightUse`，或有窗口照此刻的速度在重置前用完。
  static func tight(_ quota: AccountQuota, at now: Date) -> Bool {
    switch quota.reading(at: now) {
    case .failed: return true
    case .observed:
      if let binding = quota.binding(at: now), binding.used(at: now) >= tightUse { return true }
      return quota.windows.contains { $0.exhaustion(at: now) != nil }
    case .unobserved, .unsupported, .expired: return false
    }
  }

  /// 哪个账号："anthropic「Max 账号」"；网关的带上游（route）。
  static func account(_ quota: AccountQuota) -> String {
    let name = quota.account?.name ?? quota.account?.route
    return quota.provider + (name.map { "「\($0)」" } ?? "")
  }

  /// 信封里吃紧的一个账号一行：只写卡着的与会在重置前用完的窗口。
  static func tightLine(_ quota: AccountQuota, at now: Date) -> String {
    guard quota.reading(at: now) == .observed else { return "\(account(quota)) \(status(quota, at: now))" }
    let binding = quota.binding(at: now)
    let shown = quota.windows.filter { $0 == binding || $0.exhaustion(at: now) != nil }
    return "\(account(quota)) " + shown.map { window(quota, $0, at: now) }.joined(separator: "；")
  }

  /// look 里一个账号一行：每个窗口都写，吃紧的标出。
  static func line(_ quota: AccountQuota, at now: Date) -> String {
    let mark = tight(quota, at: now) ? "（吃紧）" : ""
    guard quota.reading(at: now) == .observed else { return "\(account(quota))\(mark) \(status(quota, at: now))" }
    return "\(account(quota))\(mark) " + quota.windows.map { window(quota, $0, at: now) }.joined(separator: "；")
  }

  /// 模型关联的那个账号卡着的窗口（按模型的周额度只算这个模型的）："本周 已用 85%"；读不到写原因。
  static func binding(_ quota: AccountQuota, model: PiModelKey, at now: Date) -> String {
    guard let window = quota.binding(at: now, model: model.id) else { return "\(account(quota)) \(status(quota, at: now))" }
    return "\(account(quota)) \(name(window)) 已用 \(percent(window, at: now))"
  }

  /// "本周 已用 85%，11-02 9:00 重置，卡着，照速度 11-01 18:00 用完"。
  private static func window(_ quota: AccountQuota, _ window: QuotaWindow, at now: Date) -> String {
    var parts = ["\(name(window)) 已用 \(percent(window, at: now))", "\(CueScheduleWords.time(window.resetsAt, now: now)) 重置"]
    if window == quota.binding(at: now) { parts.append("卡着") }
    if let out = window.exhaustion(at: now) { parts.append("照速度 \(CueScheduleWords.time(out, now: now)) 用完") }
    return parts.joined(separator: "，")
  }

  private static func percent(_ window: QuotaWindow, at now: Date) -> String { "\(Int((window.used(at: now) * 100).rounded()))%" }

  /// "5 小时""本周""Fable 本周"
  private static func name(_ window: QuotaWindow) -> String {
    let span =
      switch window.seconds {
      case QuotaWindow.week: "本周"
      case let s where s % 86_400 == 0: "\(s / 86_400) 天"
      default: "\(Int((Double(window.seconds) / 3_600).rounded())) 小时"
      }
    return [window.model, span].compactMap(\.self).joined(separator: " ")
  }

  /// 读不到时为什么。
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
