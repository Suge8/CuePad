#if os(macOS)
import CueStore
import SwiftUI

struct SessionGroup: Equatable {
    enum Key: Hashable {
        case now
        case ended(TimeSection)
    }

    let key: Key
    let sessions: [SessionState]

    static func grouped(
        live: [SessionState], ended: [SessionState], cue: CueDuty? = nil, now: Date, at moment: Speech.Moment,
        calendar: Calendar = .current
    ) -> [SessionGroup] {
        let current = live.isEmpty ? [] : [SessionGroup(key: .now, sessions: SessionState.inListOrder(live, state: \.self, cue: cue, at: moment))]
        let past = TimeSection.split(ended, date: \.stateSince, now: now, calendar: calendar)
        return current + past.map { SessionGroup(key: .ended($0.section), sessions: $0.items) }
    }
}

nonisolated struct SessionSearchData: Sendable, Equatable {
    var live: [SessionState]
    var ended: [SessionState]
    var endedTotal: Int
    var deliveries: [String: DeliveryRequest]
    var undelivered: [String: Int]

    static func read(text: String, pages: Int, at moment: Speech.Moment, from store: isolated CueStore) throws -> SessionSearchData {
        let live = try store.piSessionPage(SessionQuery(scope: .live, text: text, limit: .max))
        let ended = try store.piSessionPage(SessionQuery(scope: .ended, text: text, limit: SessionListData.pageSize * pages))
        return SessionSearchData(
            live: live.items.map(\.listed), ended: ended.items.map(\.listed), endedTotal: ended.total,
            deliveries: Dictionary((live.items + ended.items).compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first },
            undelivered: SessionListItem.undelivered(live.items + ended.items, at: moment))
    }
}

struct SessionResultList: View {
    let groups: [SessionGroup]
    let deliveries: [String: DeliveryRequest]
    let undelivered: [String: Int]
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
                LazyVStack(alignment: .leading, spacing: Spacing.hair) {
                    if groups.isEmpty {
                        Text(isFiltered ? "没有找到会话" : "还没有 Agent 会话。在终端里开一个，会话就会出现在这里")
                            .font(Typography.secondary).foregroundStyle(palette.ink2).padding(.vertical, Spacing.block)
                    }
                    ForEach(groups, id: \.key) { group in
                        header(group)
                        ForEach(group.sessions, id: \.sessionID) { row($0).id($0.sessionID) }
                    }
                    if more > 0 {
                        Button("显示更多（还有 \(more) 个）", action: loadMore)
                            .buttonStyle(PressStyle(.inline)).font(Typography.meta).foregroundStyle(palette.ink2).padding(.vertical, Spacing.item)
                    }
                }
                .padding(.vertical, Spacing.item).padding(.horizontal, Spacing.block)
            }
            .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
        }
    }

    private func header(_ group: SessionGroup) -> some View {
        let title: Dotted = switch group.key {
        case .now: Dotted(String(localized: "现在"))
        case .ended(let section): Dotted(section.title)
        }
        return SectionHeader(title, level: .group, count: group.sessions.count)
            .padding(.top, Spacing.group).padding(.bottom, Spacing.hair)
    }

    private func row(_ session: SessionState) -> some View {
        let isSelected = session.sessionID == selection
        return SessionRow(
            session: session, project: workspace.catalog?.project(session.projectID), delivery: deliveries[session.sessionID],
            undelivered: undelivered[session.sessionID] ?? 0).equatable()
            .padding(.vertical, Spacing.item)
            .contentShape(.rect)
            .row(selected: isSelected)
            .onTapGesture { open(session.sessionID) }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open(session.sessionID) }
    }
}
#endif
