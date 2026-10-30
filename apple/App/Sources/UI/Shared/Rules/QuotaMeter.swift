import CueStore
import Foundation

/// 一个订阅账号的额度怎么读（额度环与它展开的明细 `QuotaDetail`、灵动岛与锁屏的那一行，回复框的模型胶囊，模型菜单的分组标题共用一份）。
/// 口径是还剩多少（剩余，不是已用）：用户要回答的是"还够不够用"，满格是满额、往下掉是在用，同电量一样不用换算。
/// 读数（含读屏的说法与"照这速度多久用完"）全在 `now` 那一刻算定：过了重置时间的窗口显示等待更新，不画数值，不请求、也不跑定时器——界面只在新观测到达或重画时换读数，
/// 倒计时是自己走字的计时文字（`Countdown`，与"x 分钟前"的 `PiClock.Live` 同一种做法）。档位按已用算，与上下文用量同一个口径（`UsageLevel`）。
nonisolated struct QuotaMeter: Equatable {
    struct Window: Equatable, Identifiable {
        /// "5 小时"、"本周"、"Fable 本周"
        let name: String
        /// 还剩（0 到 1）
        let left: Double
        /// 匀速线：按窗口已过的时间，匀速用的话此刻该还剩多少（0 到 1）；已重置为 nil
        let even: Double?
        let resetsAt: Date
        /// 照这速度还能用多久的短语："约 2 小时"（时长写法同 `PiClock.duration`）；剩的不比匀速线少（重置前用不完）为 nil
        let runway: String?
        let level: UsageLevel
        let id: QuotaWindow.ID
        /// 读屏："5 小时剩 32%，2 小时后重置，照这速度约 1 小时后用完"。
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
            runway = window.exhaustion(at: now).map { String(localized: "约 \(PiClock.duration($0.timeIntervalSince(now)))") }
            level = UsageLevel(used: used)
            id = window.id
            let reset = String(localized: "\(Countdown(end: window.resetsAt).format(now))后重置")
            spoken = Dotted(String(localized: "\(name)剩 \(Self.percent(left))"), reset, runway.map { String(localized: "照这速度\($0)后用完") }).spoken
        }
    }

    let provider: String
    let id: UUID
    let message: String?
    let usageURL: URL?
    /// 账号叫什么：订阅的产品名（Claude、Codex，`PiProvider.account`），不是提供方（Anthropic、OpenAI）
    let account: String
    /// 显示的窗口，从短到长：整个账号的窗口全列（Claude 是 5 小时、本周，Codex 按套餐一到两个）；
    /// 按模型的周额度只在用过七成时列在后面——平时它比整个账号的本周宽松，列出来只是多读一行，快用完时才卡人
    let windows: [Window]
    let updatedAt: Date
    let isStale: Bool

    init(_ quota: AccountQuota, at now: Date) {
        provider = quota.provider
        id = quota.id
        account = quota.account?.label(provider: quota.provider) ?? PiProvider(id: quota.provider).account
        usageURL = quota.account?.usageURL(provider: quota.provider)
        message = switch quota.reading(at: now) {
        case .observed: quota.account?.source != nil && quota.isStale(at: now) ? String(localized: "上次额度观测，等待更新") : nil
        case .unsupported: usageURL != nil ? String(localized: "ChatGPT 暂不提供额度数据") : String(localized: "此授权不提供订阅额度查询")
        case .unobserved: String(localized: "尚未观测到额度")
        case .failed: String(localized: "额度查询失败")
        case .expired: String(localized: "额度观测已过期，等待更新")
        }
        let all = quota.reading(at: now) == .observed ? quota.windows.map { Window($0, at: now) } : []
        windows = all.filter { !$0.isScoped || $0.level != .roomy }
        updatedAt = quota.observedAt ?? quota.modifiedAt
        isStale = quota.isStale(at: now)
    }

    /// 模型菜单的分组标题："Claude · 5 小时剩 86% · 本周剩 92%"。
    var menuTitle: Dotted { Dotted([account] + (message.map { [$0] } ?? windows.map { String(localized: "\($0.name)剩 \($0.percent)") })) }

    /// 读屏：账号与每个窗口剩多少、多久重置。
    var spoken: String { Dotted([account] + (message.map { [$0] } ?? windows.map(\.spoken))).spoken }

    /// 到 `end` 还有多久（时长写法同 `PiClock.duration`，最后一分钟也写"1 分钟"、不读秒），给 `LiveText` 用：只在字会变的时刻重画——
    /// 一小时内每整分钟、一天内每整小时、再往后每整天（都从 `end` 往回数）。过了 `end` 不再走（那一刻由 `Moments` 睡到 `nextReset(after:)` 按过期重画）。
    struct Countdown: DiscreteFormatStyle {
        let end: Date

        func format(_ now: Date) -> String { PiClock.duration(max(end.timeIntervalSince(now), 60)) }

        /// 剩的时长在这一档单位里的整数变的那一刻（严格晚于 `now`，`Date.tick`），格子落在整单位之后 1 毫秒。
        func discreteInput(after now: Date) -> Date? {
            let left = end.timeIntervalSince(now)
            guard left > 60 else { return nil }
            return end.addingTimeInterval(0.001).tick(every: Self.unit(left), after: now)
        }

        func discreteInput(before now: Date) -> Date? {
            let left = end.timeIntervalSince(now), unit = Self.unit(left)
            return end.addingTimeInterval(-((left / unit).rounded(.down) + 1) * unit)
        }

        private static func unit(_ left: TimeInterval) -> TimeInterval { left < 3600 ? 60 : left < 86_400 ? 3600 : 86_400 }
    }

    /// 窗口长度的叫法：5 小时、本周（7 天）、其余按天或小时。
    static func windowName(seconds: Int) -> String {
        switch seconds {
        case QuotaWindow.week: String(localized: "本周")
        case let s where s % 86_400 == 0: String(localized: "\(s / 86_400) 天")
        default: String(localized: "\(Int((Double(seconds) / 3_600).rounded())) 小时")
        }
    }
}

extension [AccountQuota] {
    /// `now` 之后最近的一次窗口重置：额度读数只在新观测到达与这一刻变（`Moments` 睡到它重画）；都过了为 nil。
    nonisolated func nextReset(after now: Date) -> Date? {
        flatMap(\.windows).map(\.resetsAt).filter { $0 > now }.min()
    }
}
