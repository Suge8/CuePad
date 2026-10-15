import CueStore
import Foundation

/// 一个订阅账号的额度怎么读（Agent 页顶部与菜单栏面板的仪表、它的明细、回复框的模型胶囊、模型菜单的分组标题共用一份）。
/// 读数在 `now` 那一刻算定：过了重置时间的窗口按已重置算（0%），不请求、也不跑定时器——界面只在新观测到达或重画时换读数，
/// 倒计时是自己走字的计时文字（`Countdown`，与"x 分钟前"的 `PiClock.Live` 同一种做法）。档位与上下文用量同一个口径（`PiContextMeter.level(of:)`）。
nonisolated struct QuotaMeter: Equatable {
    /// 一个窗口此刻的读数。
    struct Window: Equatable, Identifiable {
        /// "5 小时"、"本周"、"Fable 本周"
        let name: String
        /// 已用（0 到 1）
        let used: Double
        /// 匀速刻度：按窗口已过的时间此刻该用到多少（0 到 1）
        let pace: Double
        let resetsAt: Date
        /// 照这速度什么时候用完；没超过匀速刻度为 nil
        let exhaustion: Date?
        let level: PiContextMeter.Level
        /// 过了重置时间、还没有新的观测：下一次什么时候重置不知道，只写"已重置"
        let hasReset: Bool
        /// 窗口长度与模型（`QuotaWindow.isSameWindow`）：名字是给人看的，不同长度可能写成同一个"N 小时"。
        let id: String

        var percent: String { "\(Int((used * 100).rounded()))%" }
        var isSpent: Bool { used >= 1 }

        init(_ window: QuotaWindow, at now: Date) {
            name = [window.model, QuotaMeter.windowName(seconds: window.seconds)].compactMap { $0 }.joined(separator: " ")
            used = window.used(at: now)
            pace = window.pace(at: now)
            resetsAt = window.resetsAt
            exhaustion = window.exhaustion(at: now)
            level = PiContextMeter.level(of: used)
            hasReset = now >= window.resetsAt
            id = "\(window.seconds)/\(window.model ?? "")"
        }

        /// 照这速度还能用多久的短语："约 2 小时 10 分钟"（读数时刻定下，不跟着走；与"5 小时"同一种写法，取两个单位）。
        func runway(from now: Date) -> String? {
            exhaustion.map { "约 " + QuotaMeter.span(Int($0.timeIntervalSince(now))) }
        }
    }

    let provider: String
    /// 账号叫什么：订阅的产品名（Claude、Codex，`PiProvider.account`），不是提供方（Anthropic、OpenAI）
    let account: String
    /// 仪表的圈，外到内：整个账号的窗口从短到长（Claude 是 5 小时、本周，Codex 按套餐一到两个）
    let rings: [Window]
    /// 按模型的周额度（明细里列在后面）
    let scoped: [Window]
    /// 卡着的窗口，规则见 `AccountQuota.binding(at:model:)`（提供方的判定优先，没有时取用得最多的；总览不按模型挑）
    let binding: Window?
    let updatedAt: Date
    let isStale: Bool

    init(_ quota: AccountQuota, at now: Date) {
        provider = quota.provider
        account = PiProvider(id: quota.provider).account
        rings = quota.accountWindows.map { Window($0, at: now) }
        scoped = quota.windows.filter { $0.model != nil }.map { Window($0, at: now) }
        binding = quota.binding(at: now).map { Window($0, at: now) }
        updatedAt = quota.modifiedAt
        isStale = quota.isStale(at: now)
    }

    /// 模型菜单的分组标题："Claude · 5 小时 14% · 本周 8%"。
    var menuTitle: Dotted { Dotted([account] + rings.map { "\($0.name) \($0.percent)" }) }

    /// 读屏：账号与每个窗口的用量，卡着的那个怎么样。
    var spoken: String {
        Dotted([account] + (rings + scoped).map { "\($0.name)已用 \($0.percent)" } + [binding.flatMap { $0.runway(from: .now).map { "照这速度\($0)后用完" } }]).spoken
    }

    /// 一段时长：最大的两个单位，"3 天 4 小时"、"2 小时 10 分钟"、"25 分钟"。
    static func span(_ seconds: Int) -> String {
        let minutes = max(seconds / 60, 1), hours = minutes / 60, days = hours / 24
        if days > 0 { return hours % 24 == 0 ? "\(days) 天" : "\(days) 天 \(hours % 24) 小时" }
        if hours > 0 { return minutes % 60 == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }

    /// 到 `end` 还有多久（`span` 的写法："2 小时 14 分钟"），给 `Text(.currentDate, format:)` 用：系统只在字会变的整分钟换字，
    /// 不经 TimelineView 或定时器重算视图。过了 `end` 不再走（那一刻由 `QuotaMoments` 按已重置重画）。
    struct Countdown: DiscreteFormatStyle {
        let end: Date

        func format(_ now: Date) -> String { QuotaMeter.span(Int(end.timeIntervalSince(now))) }

        /// 剩余的整分钟数变的那一刻：剩 k 分多时，在剩恰好 k 分钟之后
        func discreteInput(after now: Date) -> Date? {
            let left = end.timeIntervalSince(now)
            guard left > 60 else { return nil }
            return end.addingTimeInterval(-((left / 60).rounded(.down) * 60) + 0.001)
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
