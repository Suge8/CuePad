import CueStore
import Foundation
import Observation

/// 此刻有事的 Pi 会话（同步记录里在线的，加上还有话发给它的已结束会话，即 `PiSessionQuery.current`）：整个 App 一份，一个订阅读一次，各处不各自订阅、各读一页：
/// 读一页要查会话、项目、最近的投送请求、改名与没送达的话，会话状态每变一次，订阅了几处就读几遍。
/// 下面这些由 `items` 推出，各自相等就不写——读它们的视图只在自己用的那份变了才重算。
@Observable
final class LiveSessions {
    /// 第一份在 App 打开资料库时当场读到（`init`），之后从它接着订阅：没有"还没读到"这一态。
    private(set) var items: [PiSessionListItem] = []
    private(set) var total = 0
    private(set) var live: [PiSessionListItem] = []
    private(set) var current: [PiSessionListItem] = []
    /// 以下四项都按 Pi 的会话 id。
    private(set) var recaps: [String: PiRecap] = [:]
    private(set) var deliveries: [String: DeliveryRequest] = [:]
    private(set) var renames: [String: DeliveryRequest] = [:]
    private(set) var answers: [String: DeliveryRequest] = [:]
    private(set) var undelivered: [String: Int] = [:]
    /// 停着、这次停下 Cue 交出去的那一处还没做完的会话在等谁；各处都经 `Workspace.handoff(of:)` 读它。
    private(set) var handoffs: [String: CueHandoff] = [:]
    /// Cue 在值班时的那一份（`CueStore.cueDuty`，与会话一起读；它那台 Mac 的在线期限到点由订阅重读）。不在值班为 nil。
    private(set) var cue: CueDuty?
    /// 这次运行里在这台 Mac 上结束的会话（运行之前就已结束的历史会话不在其中），最近结束的在前，只留最近的几个。iOS 上没有。
    private(set) var recentlyEnded: [PiSessionState] = []
    /// 最近一次交给（`CueRelayStage` 画）：比已算过的更新的交给（`CueFlight.Facts`），`at` 变成新的就播一次；打开资料库时已有的不算。
    /// 叫醒那一路不在这里（`CueWatch.wake`）。
    /// 与会话一起读：重排"在做"那一列的那次写入（话在路上、新会话出现）与这次接力同一份到达界面，量落点时那一列已经排好。
    private(set) var flight: CueFlight?
    /// 与接力事实同一次读到，界面不另起订阅等待目标进入会话条。
    private(set) var rail = SessionRailData(waiting: [], advancing: [])
    @ObservationIgnored private var seen: Date?
    private let launchedAt = Date()
    /// 结束会话的那台 Mac（本机，见 `Page`）；iOS 为 nil。
    private let host: String?
    @ObservationIgnored private let start: Snapshot<Page>
    @ObservationIgnored private var page: Page
    private nonisolated static let endedWindow = 20

    init(store: CueStore, endedOn host: String?, at moment: Speech.Moment) throws {
        self.host = host
        start = try store.snapshot { [since = launchedAt] in try Page.read(from: $0, endedOn: host, since: since) }
        page = start.value
        seen = start.value.relays.latest
        apply(start.value, at: moment)
    }

    /// 这个会话正在问的那道题已有的作答请求；题换了、没答过为 nil。
    func answer(to session: PiSessionState) -> DeliveryRequest? {
        guard let promptID = session.answerableQuestion?.promptID, let request = answers[session.sessionID], request.answer?.promptID == promptID else { return nil }
        return request
    }

    func relays(session: String) -> Bool { flight?.ends.contains { $0.session == session } == true }

    func relays(task: UUID) -> Bool { flight?.ends.contains { $0.task == task } == true }

    nonisolated struct Page: Sendable, Equatable {
        var items: [PiSessionListItem]
        var total: Int
        var ended: [PiSessionState] = []
        var cue: CueDuty?
        var handoffs: [String: CueHandoff]
        var relays: CueFlight.Facts
        var rail: SessionRailData

        static func read(from store: isolated CueStore, endedOn host: String? = nil, since: Date = .now) throws -> Page {
            let items = try store.piSessionPage(.current).items
            return Page(
                items: items, total: try store.piSessionCount(),
                ended: try host.map { try store.endedSessions(on: $0, since: since, limit: LiveSessions.endedWindow) } ?? [],
                cue: try store.cueDuty(), handoffs: try store.handoffs(items.map(\.state)), relays: try CueFlight.Facts.read(from: store), rail: try SessionRailData.read(from: store))
        }
    }

    /// 此刻变了（到点、同步通断）按手里那页重推：读的东西不随此刻变，"在做"与没送达的按此刻推。
    func follow(_ services: AppServices) async throws {
        let since = launchedAt, host = host, clock = services.speechClock
        let ticking = Task { for await moment in Observations({ clock.moment }) { self.apply(self.page, at: moment) } }
        defer { ticking.cancel() }
        for try await page in services.store.observe(from: start, { try Page.read(from: $0, endedOn: host, since: since) }) {
            apply(page, at: clock.moment)
        }
    }

    func apply(_ page: Page, at moment: Speech.Moment) {
        self.page = page
        if page.items != items { items = page.items }
        if page.total != total { total = page.total }
        set(\.recentlyEnded, page.ended)
        set(\.live, page.items.filter { $0.state.state != .known(.ended) })
        set(\.current, page.items.filter { $0.isCurrent(at: moment) })
        set(\.recaps, Dictionary(live.map { ($0.state.sessionID, $0.state.recap) }) { first, _ in first })
        set(\.deliveries, Dictionary(current.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.renames, Dictionary(current.compactMap { item in item.rename.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.answers, Dictionary(current.compactMap { item in item.answer.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.undelivered, PiSessionListItem.undelivered(live, at: moment))
        set(\.handoffs, page.handoffs)
        set(\.cue, page.cue)
        set(\.rail, page.rail)
        if let next = page.relays.flight(after: seen) {
            seen = page.relays.latest
            flight = next
        }
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<LiveSessions, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}

extension AppServices {
    func startLiveSessions() {
        follow(reporting: { .syncUnavailable(String(localized: "读取在线会话失败，会话状态不再更新：\(String(describing: $0))")) }) {
            try await self.liveSessions.follow(self)
        }
    }
}
