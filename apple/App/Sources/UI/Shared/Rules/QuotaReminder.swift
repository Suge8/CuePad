import CueStore
import Foundation

/// 周额度快重置的提醒：整个账号的本周窗口在重置前 `lead` 提醒一次，不论还剩多少（文案写清剩多少、几点重置），提醒用户把额度用掉。
/// 不跑定时器：额度记录一变（`AccountQuotas.follow`）就按最新观测重排系统的定时本地通知（`AlertCenter.remind`），
/// 同一标识的待发通知原地换成最新的剩余。提醒时刻已过的不排，所以一个窗口每次重置前最多响一次：响过的不会再排，
/// 第一次观测就晚于提醒时刻的也不补。
/// 5 小时这类短窗口不提醒：几小时就转一圈，提醒只是噪音；按模型的周额度不提醒：与整个账号的本周一起重置、先卡住的是整个账号的。
nonisolated struct QuotaReminder {
    static let lead: TimeInterval = 12 * 3_600
    /// 本地通知标识的前缀：重排时认出哪些待发通知是这里排的
    static let prefix = "cuepad.quota/"

    /// 提供方与重置时刻（按分钟取整：同一窗口里提供方报的重置时刻会差几百毫秒）：换了一次重置就是新的一条
    let id: String
    let fireAt: Date
    /// "Claude 本周还剩 62%"
    let title: String
    /// "明天04:00 重置，记得用掉"
    let body: String

    private static func body(resetsAt: Date, fireAt: Date) -> String {
        let time = resetsAt.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDate(resetsAt, inSameDayAs: fireAt)
            ? String(localized: "今天\(time) 重置，记得用掉") : String(localized: "明天\(time) 重置，记得用掉")
    }

    /// `now` 之后还要响的提醒，每个账号至多一条。
    static func due(_ quotas: [AccountQuota], at now: Date) -> [QuotaReminder] {
        quotas.compactMap { quota in
            guard quota.status == .observed, quota.account?.scope != nil,
                  let window = quota.windows.first(where: { $0.seconds == QuotaWindow.week && $0.model == nil }) else { return nil }
            let fireAt = window.resetsAt.addingTimeInterval(-lead)
            guard fireAt > now else { return nil }
            let meter = QuotaMeter.Window(window, at: fireAt)
            return QuotaReminder(
                id: "\(prefix)\(quota.id)/\(Int((window.resetsAt.timeIntervalSince1970 / 60).rounded()))", fireAt: fireAt,
                title: String(localized: "\(PiProvider(id: quota.provider).account) \(meter.name)还剩 \(meter.percent)"),
                body: body(resetsAt: window.resetsAt, fireAt: fireAt))
        }
    }
}
