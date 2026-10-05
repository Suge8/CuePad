#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// ⌘K"会话"范围里的一组结果。
struct SessionGroup: Equatable {
    enum Key: Hashable {
        case project(UUID)
        /// 没绑项目的会话按文件夹归组；nil 是不知道在哪的（旧记录没有文件夹名）。
        case folder(String?)

        var isProject: Bool {
            if case .project = self { true } else { false }
        }
    }

    let key: Key
    let sessions: [PiSessionState]

    static func grouped(_ sessions: [PiSessionState]) -> [SessionGroup] {
        var buckets: [Key: [PiSessionState]] = [:]
        var order: [Key] = []
        for session in sessions {
            let key = session.projectID.map(Key.project) ?? .folder(session.folder)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(session)
        }
        let projectsFirst = order.filter(\.isProject) + order.filter { !$0.isProject }
        return projectsFirst.map { SessionGroup(key: $0, sessions: PiSessionState.inListOrder(buckets[$0] ?? [])) }
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

/// 会话范围读到的一页：会话（顺序见 `PiSessionPage`）与符合条件的总数。
nonisolated struct SessionSearchData: Sendable, Equatable {
    var sessions: [PiSessionState]
    var total: Int

    static let pageSize = 40

    static func read(text: String, pages: Int, from store: isolated CueStore) throws -> SessionSearchData {
        let page = try store.piSessionPage(PiSessionQuery(text: text, limit: pageSize * pages))
        return SessionSearchData(sessions: page.items.map(\.listed), total: page.total)
    }
}

/// 会话范围的结果列表：按 `SessionGroup` 分组，行是侧栏同一种（`PiSessionRow`）；点一下选中，右边是它的近况。
struct SessionResultList: View {
    let groups: [SessionGroup]
    let total: Int
    let isFiltered: Bool
    @Binding var selection: String?
    let more: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty {
                        Text(isFiltered ? "没有找到会话" : "还没有 Pi 会话。在终端运行 pi，会话就会出现在这里")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(groups, id: \.key) { group in
                        header(group)
                        ForEach(group.sessions, id: \.sessionID) { row($0).id($0.sessionID) }
                    }
                    let shown = groups.reduce(0) { $0 + $1.sessions.count }
                    if total > shown {
                        Button("显示更多（还有 \(total - shown) 个）", action: more)
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
            case .project(let id):
                let project = workspace.catalog?.project(id)
                ProjectGlyph(project: project, size: 11)
                Text(project?.name ?? "项目")
            case .folder(let folder):
                Image(systemName: "folder").accessibilityHidden(true)
                Text(folder ?? "其他位置")
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
            session: session, project: workspace.catalog?.project(session.projectID),
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
