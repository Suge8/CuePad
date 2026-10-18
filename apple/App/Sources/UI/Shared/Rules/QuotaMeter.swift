import CueStore
import Foundation

/// 一个订阅账号的额度怎么读（Cue 页头面板、Agent 页顶部与菜单栏面板的总览，回复框的模型胶囊，模型菜单的分组标题共用一份）。
/// 口径是还剩多少（剩余，不是已用）：用户要回答的是"还够不够用"，满格是满额、往下掉是在用，同电量一样不用换算。
/// 读数（含读屏的说法与"照这速度多久用完"）全在 `now` 那一刻算定：过了重置时间的窗口按已重置算（满额），不请求、也不跑定时器——界面只在新观测到达或重画时换读数，
/// 倒计时是自己走字的计时文字（`Countdown`，与"x 分钟前"的 `PiClock.Live` 同一种做法）。档位按已用算，与上下文用量同一个口径（`PiContextMeter.level(of:)`）。
nonisolated struct QuotaMeter: Equatable {
    /// 一个窗口此刻的读数。
    struct Window: Equatable, Identifiable {
        /// "5 小时"、"本周"、"Fable 本周"
        let name: String
        /// 还剩（0 到 1）
        let left: Double
        /// 匀速线：按窗口已过的时间，匀速用的话此刻该还剩多少（0 到 1）；已重置为 nil
        let even: Double?
        let resetsAt: Date
        /// 照这速度还能用多久的短语："约 2 小时 10 分钟"（与"5 小时"同一种写法，取两个单位）；剩的不比匀速线少（重置前用不完）为 nil
        let runway: String?
        let level: PiContextMeter.Level
        /// 过了重置时间、还没有新的观测：下一次什么时候重置不知道，只写"已重置"
        let hasReset: Bool
        let id: QuotaWindow.ID
        /// 读屏："5 小时剩 32%，2 小时 14 分钟后重置，照这速度约 1 小时后用完"。
        let spoken: String

        var percent: String { Self.percent(left) }
        private static func percent(_ left: Double) -> String { "\(Int((left * 100).rounded()))%" }
        /// 只算某个模型的（按模型的周额度）
        var isScoped: Bool { id.model != nil }

        init(_ window: QuotaWindow, at now: Date) {
            name = [window.model, QuotaMeter.windowName(seconds: window.seconds)].compactMap { $0 }.joined(separator: " ")
            let used = window.used(at: now), pace = window.pace(at: now)
            left = 1 - used
            even = pace > 0 ? 1 - pace : nil
            resetsAt = window.resetsAt
            runway = window.exhaustion(at: now).map { "约 " + QuotaMeter.span(Int($0.timeIntervalSince(now))) }
            level = PiContextMeter.level(of: used)
            hasReset = now >= window.resetsAt
            id = window.id
            let reset = hasReset ? "已重置" : "\(QuotaMeter.span(Int(window.resetsAt.timeIntervalSince(now))))后重置"
            spoken = Dotted("\(name)剩 \(Self.percent(left))", reset, runway.map { "照这速度\($0)后用完" }).spoken
        }
    }

    let provider: String
    /// 账号叫什么：订阅的产品名（Claude、Codex，`PiProvider.account`），不是提供方（Anthropic、OpenAI）
    let account: String
    /// 显示的窗口，从短到长：整个账号的窗口全列（Claude 是 5 小时、本周，Codex 按套餐一到两个）；
    /// 按模型的周额度只在用过七成时列在后面——平时它比整个账号的本周宽松，列出来只是多读一行，快用完时才卡人
    let windows: [Window]
    let updatedAt: Date
    let isStale: Bool

    init(_ quota: AccountQuota, at now: Date) {
        provider = quota.provider
        account = PiProvider(id: quota.provider).account
        let all = quota.windows.map { Window($0, at: now) }
        windows = all.filter { !$0.isScoped || $0.level != .roomy }
        updatedAt = quota.modifiedAt
        isStale = quota.isStale(at: now)
    }

    /// 模型菜单的分组标题："Claude · 5 小时剩 86% · 本周剩 92%"。
    var menuTitle: Dotted { Dotted([account] + windows.map { "\($0.name)剩 \($0.percent)" }) }

    /// 读屏：账号与每个窗口剩多少、多久重置。
    var spoken: String { Dotted([account] + windows.map(\.spoken)).spoken }

    /// 一段时长：最大的两个单位，"3 天 4 小时"、"2 小时 10 分钟"、"25 分钟"。
    static func span(_ seconds: Int) -> String {
        let minutes = max(seconds / 60, 1), hours = minutes / 60, days = hours / 24
        if days > 0 { return hours % 24 == 0 ? "\(days) 天" : "\(days) 天 \(hours % 24) 小时" }
        if hours > 0 { return minutes % 60 == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }

    /// 到 `end` 还有多久（`span` 的写法："2 小时 14 分钟"），给 `LiveText` 用：只在字会变的整分钟重画。
    /// 过了 `end` 不再走（那一刻由 `QuotaMoments` 按已重置重画）。
    struct Countdown: DiscreteFormatStyle {
        let end: Date

        func format(_ now: Date) -> String { QuotaMeter.span(Int(end.timeIntervalSince(now))) }

        /// 剩余的整分钟数变的那一刻：剩 k 分多时，在剩恰好 k 分钟之后（严格晚于 `now`，`Date.tick`）
        func discreteInput(after now: Date) -> Date? {
            guard end.timeIntervalSince(now) > 60 else { return nil }
            // 剩的分钟数在每个整分钟刚过时变：格子落在整分钟之后 1 毫秒
            return end.addingTimeInterval(0.001).tick(every: 60, after: now)
        }

        func discreteInput(before now: Date) -> Date? {
            let left = end.timeIntervalSince(now)
            return end.addingTimeInterval(-((left / 60).rounded(.down) + 1) * 60)
        }
    }

    /// 窗口长度的叫法：5 小时、本周（7 天）、其余按天或小时。
    static func windowName(seconds: Int) -> String {
        switch seconds {
        case 7 * 86_400: "本周"
        case let s where s % 86_400 == 0: "\(s / 86_400) 天"
        default: "\(Int((Double(seconds) / 3_600).rounded())) 小时"
        }
    }
}
