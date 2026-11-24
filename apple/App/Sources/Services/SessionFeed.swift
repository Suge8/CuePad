import CueStore
import Foundation
import Observation

@Observable
final class SessionFeed {
    private(set) var items: [SessionListItem] = []
    private(set) var total = 0
    private(set) var live: [SessionListItem] = []
    private(set) var current: [SessionListItem] = []
    private(set) var recorded: [String: SessionState] = [:]
    private(set) var deliveries: [String: DeliveryRequest] = [:]
    private(set) var renames: [String: DeliveryRequest] = [:]
    private(set) var answers: [String: DeliveryRequest] = [:]
    private(set) var undelivered: [String: Int] = [:]
    private(set) var handoffs: [String: CueHandoff] = [:]
    private(set) var cue: CueDuty?
    private(set) var recentlyEnded: [SessionState] = []
    private(set) var flight: CueFlight?
    private(set) var rail = SessionRailData(waiting: [], advancing: [])
    private(set) var marks: [String: SessionMarks] = [:]
    @ObservationIgnored private var seen: Date?
    private let launchedAt = Date()
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

    func answer(to session: SessionState) -> DeliveryRequest? {
        guard let promptID = session.answerableQuestion?.promptID, let request = answers[session.sessionID], request.answer?.promptID == promptID else { return nil }
        return request
    }

    func relays(session: String) -> Bool { flight?.ends.contains { $0.session == session } == true }

    func relays(task: UUID) -> Bool { flight?.ends.contains { $0.task == task } == true }

    nonisolated struct Page: Sendable, Equatable {
        var items: [SessionListItem]
        var total: Int
        var ended: [SessionState] = []
        var cue: CueDuty?
        var handoffs: [String: CueHandoff]
        var relays: CueFlight.Facts
        var rail: SessionRailData
        var marks: [String: SessionMarks]

        static func read(from store: isolated CueStore, endedOn host: String? = nil, since: Date = .now) throws -> Page {
            let items = try store.sessionPage(.current).items
            return Page(
                items: items, total: try store.sessionCount(),
                ended: try host.map { try store.endedSessions(on: $0, since: since, limit: SessionFeed.endedWindow) } ?? [],
                cue: try store.cueDuty(), handoffs: try store.handoffs(items.map(\.state)), relays: try CueFlight.Facts.read(from: store), rail: try SessionRailData.read(from: store),
                marks: try store.sessionMarks())
        }
    }

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
        set(\.recorded, Dictionary(live.map { ($0.state.sessionID, $0.state) }) { first, _ in first })
        set(\.deliveries, Dictionary(current.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.renames, Dictionary(current.compactMap { item in item.rename.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.answers, Dictionary(current.compactMap { item in item.answer.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.undelivered, SessionListItem.undelivered(live, at: moment))
        set(\.handoffs, page.handoffs)
        set(\.cue, page.cue)
        set(\.rail, page.rail)
        set(\.marks, page.marks)
        if let next = page.relays.flight(after: seen) {
            seen = page.relays.latest
            flight = next
        }
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<SessionFeed, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}

extension AppServices {
    func startSessionFeed() {
        follow(reporting: { .syncUnavailable(String(localized: "读取在线会话失败，会话状态不再更新：\(String(describing: $0))")) }) {
            try await self.sessionFeed.follow(self)
        }
        follow { for await marks in Observations({ self.sessionFeed.marks }) { await self.alerts?.dismissSeen(marks) } }
    }
}
