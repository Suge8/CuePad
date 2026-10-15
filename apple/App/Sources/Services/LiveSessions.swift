import CueStore
import Foundation
import Observation

/// 此刻有事的 Pi 会话（同步记录里在线的，加上还有话发给它的已结束会话，即 `PiSessionQuery.current`）：整个 App 一份，一个订阅读一次。
/// 书架、侧栏的"此刻"、前台提示、发送菜单、Mac 的会话摘要都从这里取，不各自订阅、各读一页：
/// 读一页要查会话、项目、最近的投送请求、改名与没送达的话，会话状态每变一次，订阅了几处就读几遍。
/// 下面这些由 `items` 推出，各自相等就不写——读它们的视图只在自己用的那份变了才重算。
@Observable
final class LiveSessions {
    /// 此刻有事的会话：未结束的在前，各自按进入当前状态的时间从新到旧（`piSessionPage` 的顺序）。nil 是启动后还没读到第一份：
    /// 项目的"此刻"（`ProjectNow.byProject`）在它到之前只留空白，不先按"没有会话"写任务、读到后再换成会话状态。
    private(set) var items: [PiSessionListItem]?
    /// 全部会话记录数（含历史）。
    private(set) var total = 0
    /// 在线会话的摘要、发给它们的最近一条投送请求与改名、此刻没能送达的话有几句，按 Pi 的会话 id。
    private(set) var recaps: [String: PiRecap] = [:]
    private(set) var deliveries: [String: DeliveryRequest] = [:]
    private(set) var renames: [String: DeliveryRequest] = [:]
    private(set) var undelivered: [String: Int] = [:]
    /// Cue 在值班（`CueStore.cueOnDuty`，与会话一起读；它那台 Mac 的在线期限到点由订阅重读）：会话的显示与"等你"的提示据此分等你还是等 Cue。
    private(set) var cueOnDuty = false
    /// 这次运行里在这台 Mac 上结束的会话（运行之前就已结束的历史会话不在其中），最近结束的在前，只留最近的几个：
    /// Mac 的发送目标认出"刚结束的会话"、给已结束的目标写会话名都读它。iOS 上没有。
    private(set) var recentlyEnded: [PiSessionState] = []
    private let launchedAt = Date()
    private nonisolated static let endedWindow = 20

    /// 在线的会话（`items` 里没结束的）。
    var live: [PiSessionListItem] { (items ?? []).filter { $0.state.state != .known(.ended) } }

    /// 一次读到的：`current` 一页与会话总数；给了 `host`（Mac）时再加上那台 Mac 上 `since` 之后结束的会话。
    nonisolated struct Page: Sendable, Equatable {
        var items: [PiSessionListItem]
        var total: Int
        var ended: [PiSessionState] = []
        var cueOnDuty = false

        static func read(from store: isolated CueStore, at moment: Speech.Moment, endedOn host: String? = nil, since: Date = .now) throws -> Page {
            Page(
                items: try store.piSessionPage(.current).items, total: try store.piSessionCount(),
                ended: try host.map { try store.endedSessions(on: $0, since: since, limit: LiveSessions.endedWindow) } ?? [],
                cueOnDuty: try store.cueOnDuty())
        }
    }

    /// 跟随同步记录与此刻（`AppServices.observeTimed`：到点、同步通断时重读）直到任务取消。
    func follow(_ services: AppServices, endedOn host: String? = nil) async throws {
        let since = launchedAt
        do {
            for try await (page, moment) in services.observeTimed({ try Page.read(from: $0, at: $1, endedOn: host, since: since) }) {
                apply(page, at: moment)
            }
        } catch {
            // 读失败由调用方报告；等着第一份的页面（项目的"此刻"）不因此一直空着，按没有会话排
            if items == nil { items = [] }
            throw error
        }
    }

    func apply(_ page: Page, at moment: Speech.Moment) {
        if page.items != items { items = page.items }
        if page.total != total { total = page.total }
        set(\.recentlyEnded, page.ended)
        let live = self.live
        set(\.recaps, Dictionary(live.map { ($0.state.sessionID, $0.state.recap) }) { first, _ in first })
        set(\.deliveries, Dictionary(live.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.renames, Dictionary(live.compactMap { item in item.rename.map { (item.state.sessionID, $0) } }) { first, _ in first })
        set(\.undelivered, PiSessionListItem.undelivered(live, at: moment))
        set(\.cueOnDuty, page.cueOnDuty)
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<LiveSessions, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}

extension AppServices {
    /// 开始跟随在线会话（`start()` 调用）；读失败时报告并停止。
    func startLiveSessions() {
        follow(reporting: { .syncUnavailable("读取在线会话失败，会话状态不再更新：\($0)") }) {
            #if os(macOS)
            try await self.liveSessions.follow(self, endedOn: self.hostID)
            #else
            try await self.liveSessions.follow(self)
            #endif
        }
    }
}
