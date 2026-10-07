#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// ⌘K"会话"范围里的一组结果。
struct SessionGroup: Equatable {
    enum Key: Hashable {
        /// 在线的会话。
        case now
        /// 已结束的，按结束时间分段（`PiHistorySection`）。
        case ended(PiHistorySection)
    }

    let key: Key
    let sessions: [PiSessionState]

    static func grouped(live: [PiSessionState], ended: [PiSessionState], now: Date, calendar: Calendar = .current) -> [SessionGroup] {
        let current = live.isEmpty ? [] : [SessionGroup(key: .now, sessions: PiSessionState.inListOrder(live))]
        let past = PiHistorySection.split(ended, date: \.stateSince, now: now, calendar: calendar)
        return current + past.map { SessionGroup(key: .ended($0.section), sessions: $0.items) }
    }
}

/// ⌘K 搜什么：卡片或 Pi 会话。每次打开 ⌘K 从卡片开始；侧栏"全部 N 个"直接进会话。
enum SearchScope: Hashable {
    case cards, sessions
}

extension EnvironmentValues {
    /// 打开 ⌘K 并停在会话范围（侧栏"全部 N 个"）；主窗口提供。
    @Entry var openSessionSearch: (() -> Void)?
}

nonisolated extension PiSessionListItem {
    /// 列表里的会话；所属项目已删的不再带项目（按文件夹归组、写文件夹名）。
    var listed: PiSessionState {
        var session = state
        if project == nil { session.projectID = nil }
        return session
    }
}

/// 会话范围读到的：全部在线的（不多，不分页）与已结束的前若干页（从新到旧），同一个搜索词。
nonisolated struct SessionSearchData: Sendable, Equatable {
    var live: [PiSessionState]
    var ended: [PiSessionState]
    /// 符合搜索的已结束会话总数（"显示更多"）。
    var endedTotal: Int
    /// 发给这些会话的最近一条投送请求（Pi 的会话 id →）。
    var deliveries: [String: DeliveryRequest]

    static let pageSize = 40

    static func read(text: String, pages: Int, from store: isolated CueStore) throws -> SessionSearchData {
        let live = try store.piSessionPage(PiSessionQuery(scope: .live, text: text, limit: .max))
        let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, text: text, limit: pageSize * pages))
        return SessionSearchData(
            live: live.items.map(\.listed), ended: ended.items.map(\.listed), endedTotal: ended.total,
            deliveries: Dictionary((live.items + ended.items).compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first })
    }
}

/// 会话范围的结果列表：按 `SessionGroup` 分组，行是侧栏同一种（`PiSessionRow`）；点一下选中，右边是它的近况。
struct SessionResultList: View {
    let groups: [SessionGroup]
    let deliveries: [String: DeliveryRequest]
    /// 还没读到的已结束会话有多少（"显示更多"）。
    let more: Int
    let isFiltered: Bool
    @Binding var selection: String?
    let loadMore: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty {
                        Text(isFiltered ? "没有找到会话" : "还没有 Agent 会话。在终端运行 pi，会话就会出现在这里")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(groups, id: \.key) { group in
                        header(group)
                        ForEach(group.sessions, id: \.sessionID) { row($0).id($0.sessionID) }
                    }
                    if more > 0 {
                        Button("显示更多（还有 \(more) 个）", action: loadMore)
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(8)
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
            Text("\(group.sessions.count)").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ session: PiSessionState) -> some View {
        let isSelected = session.sessionID == selection
        return PiSessionRow(
            session: session, project: workspace.catalog?.project(session.projectID), delivery: deliveries[session.sessionID],
            nameFont: .system(size: 13.5), lineFont: .system(size: 11.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isSelected ? palette.fill.opacity(3) : .clear, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
            .onTapGesture { selection = session.sessionID }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = session.sessionID }
    }
}
#endif
