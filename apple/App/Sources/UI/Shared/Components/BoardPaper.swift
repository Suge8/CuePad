import SwiftUI

/// 待办、推进中、做完一列的那张纸：行是全 App 那一种任务行（`TaskLine`，上级收成一行、状态看此刻干活的叶子），没绑任务的活会话是会话列表的那一行。
/// 看的是全部项目时按项目分段（`BoardSection`），段头写一次项目（`BoardProjectHeading`）；只有一件的项目也不另起一张纸：一列一张，读着是一份清单。
struct BoardPaper<Row: Identifiable, Content: View>: View {
    let rows: [Row]
    let project: (Row) -> UUID?
    @ViewBuilder let content: (Row) -> Content
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if !rows.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(BoardSection.of(rows, by: project)) { section in
                    BoardProjectHeading(id: section.id, first: section.first).padding(.leading, BoardInset.ring)
                    ForEach(section.rows) { content($0) }
                }
            }
            .padding(BoardInset.paper)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: TaskMetrics.cardRadius)
        }
    }
}

/// 看板一列里按项目分的一段，段的先后是它第一次出现的先后；不属于哪个项目的（Cue 的一般提问）在最前。
struct BoardSection<Row: Identifiable>: Identifiable {
    var id: UUID?
    var rows: [Row]
    var first = false

    static func of(_ rows: [Row], by project: (Row) -> UUID?) -> [Self] {
        var sections: [Self] = []
        for row in rows {
            let key = project(row)
            if let index = sections.firstIndex(where: { $0.id == key }) { sections[index].rows.append(row) } else { sections.append(Self(id: key, rows: [row])) }
        }
        if let index = sections.firstIndex(where: { $0.id == nil }), index > 0 { sections.insert(sections.remove(at: index), at: 0) }
        if !sections.isEmpty { sections[0].first = true }
        return sections
    }
}

/// 段头：项目小图标与名字，淡墨小字；第一段贴着上沿，其后的与上一段隔一点。不属于哪个项目的段、只看一个项目时（范围已经说了，`Workspace.scopedProject`）不写。
struct BoardProjectHeading: View {
    let id: UUID?
    let first: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if workspace.scopedProject == nil, let project = workspace.catalog?.project(id) {
            HStack(spacing: 5) {
                ProjectGlyph(project: project, size: Self.glyph)
                Text(project.name).lineLimit(1)
            }
            .font(TaskMetrics.caption.weight(.medium)).foregroundStyle(palette.ink3)
            .padding(.top, first ? 6 : 14).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 10
    #else
    private static let glyph: CGFloat = 12
    #endif
}

/// 纸与卡里的对齐：手机的行没有左右内边距（圈那一列自带点按宽），段头、会话行与卡里的任务行按 `ring` 让到圈的位置。
enum BoardInset {
    #if os(macOS)
    static let paper = EdgeInsets(top: 4, leading: 12, bottom: 6, trailing: 12)
    static let ring: CGFloat = 0
    #else
    /// 右边留一点，行尾的状态标不贴边。
    static let paper = EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 10)
    static let ring: CGFloat = (TaskMetrics.ringColumn - TaskMetrics.ring) / 2
    #endif
}

extension Workspace {
    /// 推进中的先后：行上写出状态词的（要你管：等你、出错、被打断、有新回复…，`PiShown.speaksOnTask`）在前，其次在跑的，再次歇着的；同一档保持原来的先后。
    func byAttention(_ work: [TaskBoard.Work], agents: AgentLinks) -> [TaskBoard.Work] {
        func rank(_ work: TaskBoard.Work) -> Int {
            let shown: PiShown? = switch work.work {
            case .task:
                work.item.flatMap { item -> PiShown? in
                    guard case .agent(let shown, _)? = next(for: item.task, lead: item.leaf, in: agents, steps: item.steps) else { return nil }
                    return shown
                }
            case .session(let session): self.shown(session, delivery: services.liveSessions.deliveries[session.sessionID])
            }
            guard let shown else { return 2 }
            return shown.speaksOnTask ? 0 : shown.isRunning ? 1 : 2
        }
        return work.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}
