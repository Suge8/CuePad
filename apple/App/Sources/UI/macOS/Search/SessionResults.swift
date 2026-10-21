#if os(macOS)
import CueStore
import SwiftUI

/// ⌘K"会话"范围里的一组结果。
struct SessionGroup: Equatable {
    enum Key: Hashable {
        case now
        /// 已结束的，按结束时间分段（`TimeSection`）。
        case ended(TimeSection)
    }

    let key: Key
    let sessions: [PiSessionState]

    static func grouped(
        live: [PiSessionState], ended: [PiSessionState], cue: CueDuty? = nil, now: Date, at moment: Speech.Moment,
        calendar: Calendar = .current
    ) -> [SessionGroup] {
        let current = live.isEmpty ? [] : [SessionGroup(key: .now, sessions: PiSessionState.inListOrder(live, state: \.self, cue: cue, at: moment))]
        let past = TimeSection.split(ended, date: \.stateSince, now: now, calendar: calendar)
        return current + past.map { SessionGroup(key: .ended($0.section), sessions: $0.items) }
    }
}

/// ⌘K 搜什么：卡片或 Agent 会话。每次打开 ⌘K 从卡片开始。
enum SearchScope: Hashable {
    case cards, sessions
}

/// 会话范围读到的：全部在线的（不多，不分页）与已结束的前若干页（从新到旧），同一个搜索词。
nonisolated struct SessionSearchData: Sendable, Equatable {
    var live: [PiSessionState]
    var ended: [PiSessionState]
    /// 符合搜索的已结束会话总数（"显示更多"）。
    var endedTotal: Int
    /// 发给这些会话的最近一条投送请求（Pi 的会话 id →）。
    var deliveries: [String: DeliveryRequest]
    /// 此刻没能送达的话有几句（会话行的小标记）。
    var undelivered: [String: Int]

    static func read(text: String, pages: Int, at moment: Speech.Moment, from store: isolated CueStore) throws -> SessionSearchData {
        let live = try store.piSessionPage(PiSessionQuery(scope: .live, text: text, limit: .max))
        let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, text: text, limit: PiSessionList.pageSize * pages))
        return SessionSearchData(
            live: live.items.map(\.listed), ended: ended.items.map(\.listed), endedTotal: ended.total,
            deliveries: Dictionary((live.items + ended.items).compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first },
            undelivered: PiSessionListItem.undelivered(live.items + ended.items, at: moment))
    }
}

/// 会话范围的结果列表：按 `SessionGroup` 分组，行是侧栏同一种（`PiSessionRow`）；方向键移动选中，点一下或 ↩ 打开它的整页（`open`）。
struct SessionResultList: View {
    let groups: [SessionGroup]
    let deliveries: [String: DeliveryRequest]
    let undelivered: [String: Int]
    /// 还没读到的已结束会话有多少（"显示更多"）。
    let more: Int
    let isFiltered: Bool
    @Binding var selection: String?
    let open: (String) -> Void
    let loadMore: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty {
                        Text(isFiltered ? "没有找到会话" : "还没有 Agent 会话。在终端里开一个，会话就会出现在这里")
                            .font(Typography.secondary).foregroundStyle(palette.ink2).padding(.vertical, 16)
                    }
                    ForEach(groups, id: \.key) { group in
                        header(group)
                        ForEach(group.sessions, id: \.sessionID) { row($0).id($0.sessionID) }
                    }
                    if more > 0 {
                        Button("显示更多（还有 \(more) 个）", action: loadMore)
                            .buttonStyle(PressStyle(.inline)).font(Typography.meta).foregroundStyle(palette.ink2).padding(.vertical, 10)
                    }
                }
                // 行的底向两边让出一截，留在滚动区里
                .padding(.vertical, 8).padding(.horizontal, 18)
            }
            .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
        }
    }

    private func header(_ group: SessionGroup) -> some View {
        HStack(spacing: 6) {
            switch group.key {
            case .now: Text("现在")
            case .ended(let section): Text(section.title)
            }
            Text("\(group.sessions.count)").foregroundStyle(palette.ink3)
        }
        .font(Typography.label).foregroundStyle(palette.ink2)
        .padding(.top, 10).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ session: PiSessionState) -> some View {
        let isSelected = session.sessionID == selection
        return PiSessionRow(
            session: session, project: workspace.catalog?.project(session.projectID), delivery: deliveries[session.sessionID],
            undelivered: undelivered[session.sessionID] ?? 0).equatable()
            .padding(.vertical, 7)
            .contentShape(.rect)
            .row(selected: isSelected)
            .onTapGesture { open(session.sessionID) }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open(session.sessionID) }
    }
}
#endif
