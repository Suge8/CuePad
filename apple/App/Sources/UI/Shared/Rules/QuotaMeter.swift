import CueStore
import Foundation

/// 口径是还剩多少（剩余，不是已用）：用户要回答的是"还够不够用"，满格是满额、往下掉是在用，同电量一样不用换算。
/// 读数（含读屏的说法与"照这速度多久用完"）全在 `now` 那一刻算定：过了重置时间的窗口显示等待更新，不画数值，不请求、也不跑定时器——界面只在新观测到达或重画时换读数，
/// 倒计时是自己走字的计时文字（`Countdown`，与"x 分钟前"的 `PiClock.Live` 同一种做法）。档位按已用算，与上下文用量同一个口径（`UsageLevel`）。
nonisolated struct QuotaMeter: Equatable {
    struct Window: Equatable, Identifiable {
        let name: String
        let left: Double
        /// 匀速线：按窗口已过的时间，匀速用的话此刻该还剩多少（0 到 1）；已重置为 nil
        let even: Double?
        let resetsAt: Date
        /// 照这速度还能用多久的短语："约 2 小时"（时长写法同 `PiClock.duration`）；剩的不比匀速线少（重置前用不完）为 nil
        let runway: String?
        let level: UsageLevel
        let id: QuotaWindow.ID
        let spoken: String

        var percent: String { Self.percent(left) }
        private static func percent(_ left: Double) -> String {
            left.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero))
        }
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
    let account: String
    /// 网关的全名是扩展拼的"Magpie / 产品 / 账号 / 上游"，打头的"Magpie"在每张卡上都一样，不再写。
    let product: String
    let identity: String?
    let source: String?
    var shownIdentity: String?
    let status: Status?
    let owes: Bool

    enum Status: Equatable {
        case stale(Date), failed, expired, unobserved, unsupported
    }
    /// 按模型的周额度只在用过七成时列在后面——平时它比整个账号的本周宽松，列出来只是多读一行，快用完时才卡人
    let windows: [Window]
    let balance: String?
    let plan: String?
    let values: [QuotaDetails.Value]
    let updatedAt: Date?

    init(_ quota: AccountQuota, at now: Date, source: String? = nil) {
        provider = quota.provider
        id = quota.id
        account = Dotted(quota.account?.label(provider: quota.provider) ?? PiProvider(id: quota.provider).account, source).visible
        (product, identity) = Self.names(quota)
        self.source = source
        usageURL = quota.account?.usageURL(provider: quota.provider)
        status = switch quota.reading(at: now) {
        case .observed: quota.isStale(at: now) ? quota.observedAt.map(Status.stale) : nil
        case .unsupported: .unsupported
        case .unobserved: .unobserved
        case .failed: .failed
        case .expired: .expired
        }
        message = switch quota.reading(at: now) {
        case .observed: quota.account?.source != nil && quota.isStale(at: now) ? String(localized: "上次观测，等待更新") : nil
        case .unsupported: usageURL != nil ? String(localized: "ChatGPT 暂不提供额度数据") : String(localized: "此授权不提供额度或余额查询")
        case .unobserved: quota.details?.kind == "balance" ? String(localized: "余额未知，等待新观测") : String(localized: "尚未观测到额度")
        case .failed: quota.details?.kind == "balance" ? String(localized: "余额查询失败") : String(localized: "额度查询失败")
        case .expired: String(localized: "额度观测已过期，等待更新")
        }
        let all = quota.reading(at: now) == .observed ? quota.windows.map { Window($0, at: now) } : []
        windows = all.filter { !$0.isScoped || $0.level != .roomy }
        balance = quota.account?.scope != nil && quota.observedAt != nil ? quota.details?.balance : nil
        owes = balance.map(Self.negative) ?? false
        plan = quota.details?.plan
        values = quota.reading(at: now) == .observed ? quota.details?.values ?? [] : []
        updatedAt = quota.observedAt
    }

    static func names(_ quota: AccountQuota) -> (product: String, identity: String?) {
        guard quota.account?.source != nil, let name = quota.account?.name else {
            return (quota.account?.label(provider: quota.provider) ?? PiProvider(id: quota.provider).account, nil)
        }
        let parts = name.components(separatedBy: " / ").dropFirst()
        return (parts.first ?? name, parts.count > 1 ? parts.dropFirst().joined(separator: " / ") : nil)
    }

    /// 账号在明细、额度环与菜单栏面板里的先后：按产品名，同一产品按账号名，再按所属 Mac 与记录定死。不看写入时间，刷新不挪位置。
    static func ordered(_ quotas: [AccountQuota]) -> [AccountQuota] {
        quotas.map { (names($0), $0) }.sorted { a, b in
            for (x, y) in [(a.0.product, b.0.product), (a.0.identity ?? "", b.0.identity ?? ""), (a.1.hostID, b.1.hostID)] where x != y {
                return x.localizedStandardCompare(y) == .orderedAscending
            }
            return a.1.id.uuidString < b.1.id.uuidString
        }.map(\.1)
    }

    private static func negative(_ text: String) -> Bool {
        zip(text, text.dropFirst()).contains { ($0 == "-" || $0 == "\u{2212}") && $1.isNumber }
    }

    static func all(_ quotas: [AccountQuota], at now: Date) -> [Self] {
        var meters = labeled(quotas, at: now)
        for (_, indices) in Dictionary(grouping: meters.indices, by: { meters[$0].product }) where indices.count > 1 {
            let short = indices.map { meters[$0].identity.map { $0.split(separator: "@").first.map(String.init) ?? $0 } }
            let unique = Set(short.compactMap { $0 }).count == short.count
            for (index, name) in zip(indices, short) { meters[index].shownIdentity = unique ? name : meters[index].identity }
        }
        return meters
    }

    private static func labeled(_ quotas: [AccountQuota], at now: Date) -> [Self] {
        let gateways = quotas.filter { $0.account?.source != nil }
        let hosts = Array(Set(gateways.map(\.hostID))).sorted()
        let sources = Dictionary(grouping: gateways, by: \.hostID).mapValues { Array(Set($0.compactMap { $0.account?.source })).sorted() }
        let multiple = sources.values.reduce(0) { $0 + $1.count } > 1
        return quotas.map { quota in
            guard multiple, let source = quota.account?.source, let own = sources[quota.hostID], let index = own.firstIndex(of: source) else {
                return Self(quota, at: now)
            }
            var mac: String?
            if hosts.count > 1 {
                let sameName = Set(gateways.filter { $0.macName == quota.macName }.map(\.hostID)).sorted()
                mac = sameName.count > 1 ? "\(quota.macName) \(sameName.firstIndex(of: quota.hostID)! + 1)" : quota.macName
            }
            let gateway = own.count > 1 ? String(localized: "网关 \(index + 1)") : nil
            return Self(quota, at: now, source: Dotted(mac, gateway).visible)
        }
    }

    var menuTitle: Dotted { Dotted([account] + [balance].compactMap { $0 } + (message.map { [$0] } ?? windows.map { String(localized: "\($0.name)剩 \($0.percent)") })) }

    var spoken: String { Dotted([account] + [balance].compactMap { $0 } + (message.map { [$0] } ?? windows.map(\.spoken))).spoken }

    /// 过了 `end` 不再走（那一刻由 `Moments` 睡到 `nextReset(after:)` 按过期重画）。
    struct Countdown: DiscreteFormatStyle {
        let end: Date

        func format(_ now: Date) -> String { PiClock.duration(max(end.timeIntervalSince(now), 60)) }

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

    static func windowName(seconds: Int) -> String {
        switch seconds {
        case QuotaWindow.week: String(localized: "本周")
        case let s where s % 86_400 == 0: String(localized: "\(s / 86_400) 天")
        default: String(localized: "\(Int((Double(seconds) / 3_600).rounded())) 小时")
        }
    }
}

extension [AccountQuota] {
    /// 只重画读数，不发网络请求。
    nonisolated func nextReset(after now: Date) -> Date? {
        let resets = flatMap(\.windows).map(\.resetsAt) + flatMap { $0.details?.values.compactMap(\.resetsAt) ?? [] }
        let stale = compactMap { $0.observedAt?.addingTimeInterval(AccountQuota.staleAfter) }
        return (resets + stale).filter { $0 > now }.min()
    }
}
