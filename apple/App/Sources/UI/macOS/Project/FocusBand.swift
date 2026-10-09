#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 任务与 Agent：本项目任务（"任务 完成数/总数"，前几条顶层任务连同子任务，可拖动、缩进，同任务面板）+ 本项目的 Agent 会话。介绍在页头。
/// Agent 一栏只在有话可说时出现：有在线会话，或项目还没绑文件夹而有同名建议、正在绑（绑定引导，`FolderGuide.shows`）；
/// 否则任务独占整张纸，不留一栏"没有运行中的会话"。
/// 纸有最大宽度：任务行尾的折起、计数与"完成"跟着内容走，不在大窗口里甩到一千点开外。
struct FocusBand: View {
    let data: ProjectPageData
    let agents: [ProjectAgents.Row]
    let guide: FolderGuide?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static let visibleTasks = 4
    /// 窄于这个宽度时两栏改成上下排，每栏都能放下一整行任务。
    private static let stackedBelow: CGFloat = 640
    /// 任务一栏最宽多少（项目页顶上的绑定引导同宽），Agent 一栏多宽。
    static let tasksWidth: CGFloat = 760
    private static let agentWidth: CGFloat = 300

    var body: some View {
        Group {
            if showsAgent { columns } else { column { tasks } }
        }
        .paper(radius: 18)
        .frame(maxWidth: showsAgent ? Self.tasksWidth + Self.agentWidth : Self.tasksWidth, alignment: .leading)
    }

    private var showsAgent: Bool {
        !agents.isEmpty
            || data.project.map { !workspace.hasFolder($0.id) && guide?.shows($0.id, in: .inset) == true } == true
    }

    private var columns: some View {
        // 由排版当场选：横排的理想宽度钉在 stackedBelow，放得下就横排，否则上下排。不读几何、不写状态
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                column { tasks }
                divider
                column { PiColumn(project: data.project, agents: agents, guide: guide) }
                    .frame(maxWidth: Self.agentWidth)
            }
            .frame(minWidth: Self.stackedBelow, idealWidth: Self.stackedBelow, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                column { tasks }
                Divider().overlay(palette.hair).padding(.horizontal, 18)
                column { PiColumn(project: data.project, agents: agents, guide: guide) }
            }
        }
    }

    @ViewBuilder private var tasks: some View {
        SectionLabel(text: TaskCopy.section(data.taskProgress), systemImage: "checklist")
        let roots = data.tasks.roots
        // 与任务面板同一节奏：任务行、"还有 N 条"、添加任务之间不再加栏内间距
        VStack(alignment: .leading, spacing: 2) {
            TaskOutline(tree: data.tasks, roots: Array(roots.prefix(Self.visibleTasks))) { row in
                TaskRow(
                    task: row.task, session: workspace.liveState(ofSession: row.task.piSessionID), marks: data.children[row.id], compact: true)
            }
            if roots.count > Self.visibleTasks {
                Button("还有 \(roots.count - Self.visibleTasks) 条") { workspace.overlay = .tasks }
                    .buttonStyle(.plain).font(Typography.meta).foregroundStyle(palette.ink3)
            }
            NewTaskField(project: data.project?.id)
        }
    }

    private var divider: some View {
        Rectangle().fill(palette.hair).frame(width: 1).padding(.vertical, 14)
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 本项目此刻在线的 Agent 会话（与侧栏同一份"现在"，别的 Mac 上的写在哪台 Mac 上）；项目还没绑文件夹又没有会话时是绑定引导。
private struct PiColumn: View {
    /// 未分类没有项目，也就没有文件夹可绑。
    let project: Project?
    let agents: [ProjectAgents.Row]
    let guide: FolderGuide?
    @Environment(\.palette) private var palette

    var body: some View {
        SectionLabel(text: "Agent", systemImage: "terminal")
        if agents.isEmpty, let project {
            ProjectFolderGuide(project: project, guide: guide, style: .inset)
        }
        ForEach(agents) { row in
            VStack(alignment: .leading, spacing: 2) {
                PiSessionRow(session: row.state, project: project, delivery: row.delivery)
                if let host = row.hostName {
                    Label("在 \(host) 上", systemImage: "laptopcomputer").font(Typography.meta).foregroundStyle(palette.ink3)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sessionLink(row.state.sessionID)
        }
    }
}

/// 项目页 Agent 栏的行：与侧栏同一份"现在"（`PiSessionState.liveRows`），只是限在这个项目；别的 Mac 上的带上那台 Mac 的名字
/// （从项目的目录绑定里取，取不到写"另一台 Mac"）。
enum ProjectAgents {
    struct Row: Identifiable {
        let state: PiSessionState
        var delivery: DeliveryRequest?
        /// 会话在哪台 Mac 上；本机为 nil。
        let hostName: String?
        var id: String { state.sessionID }
    }

    static let otherMac = "另一台 Mac"

    static func rows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:], bindings: [DirectoryBinding],
        host: String
    ) -> [Row] {
        PiSessionState.liveRows(live: live, recorded: recorded, deliveries: deliveries).map { state in
            Row(
                state: state, delivery: deliveries[state.sessionID],
                hostName: state.hostID == host
                    ? nil : bindings.first { $0.hostID == state.hostID && $0.projectID == state.projectID }?.hostName ?? otherMac)
        }
    }
}

/// 项目页读的同步会话：这个项目在线的会话（含别的 Mac 上的）、发给它们的最近一条投送请求、项目在各台 Mac 上的目录绑定。
nonisolated struct ProjectSessions: Sendable, Equatable {
    var recorded: [PiSessionState]
    var deliveries: [String: DeliveryRequest]
    var bindings: [DirectoryBinding]

    static let tables: Set<StoreTable> = [.piSessionStates, .deliveryRequests, .directoryBindings]

    static func read(_ project: UUID, from store: isolated CueStore) throws -> ProjectSessions {
        let items = try store.piSessionPage(PiSessionQuery(scope: .live, project: project, limit: .max)).items
        return ProjectSessions(
            recorded: items.map(\.listed),
            deliveries: Dictionary(items.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first },
            bindings: try store.directoryBindings().filter { $0.projectID == project })
    }
}

extension Workspace {
    /// 这个项目此刻在线的 Agent 会话：本机桥上的（实时）与同步来的（别的 Mac 上的）。
    func projectAgents(_ project: UUID?, synced: ProjectSessions?) -> [ProjectAgents.Row] {
        guard let project else { return [] }
        let live = liveSessions(in: project).map {
            PiSessionState.live($0, hostID: services.hostID, projectID: project, recap: sessionRecaps[$0.sessionID])
        }
        return ProjectAgents.rows(
            live: live, recorded: synced?.recorded ?? [], deliveries: sessionDeliveries.merging(synced?.deliveries ?? [:]) { local, _ in local },
            bindings: synced?.bindings ?? [], host: services.hostID)
    }
}

/// 下滚后收成的悬浮标题：一块玻璃写项目名、任务完成数/总数与 Agent 状态；点一下回到顶部。
struct CompactFocus: View {
    let data: ProjectPageData
    let agents: [ProjectAgents.Row]
    let scrollToTop: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let session = agents.first
        Button(action: scrollToTop) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ProjectGlyph(project: data.project, size: 13)
                    Text(data.project?.name ?? CaptureCopy.inbox).font(Typography.toolbarTitle).lineLimit(1)
                }
                Label(data.taskProgress.map { "任务 \($0.done)/\($0.total)" } ?? "任务", systemImage: "checklist").foregroundStyle(palette.ink2)
                if let session {
                    let shown = services.settings.shown(session.state, delivery: session.delivery)
                    HStack(spacing: 6) {
                        PiStateDot(shown: shown, size: 5)
                        Text("\(session.state.title) \(shown.label)")
                    }
                    .foregroundStyle(palette.ink2)
                }
            }
            .font(Typography.toolbarLabel)
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 16).frame(height: Spacing.toolbarControl)
            .glass(in: .capsule, interactive: true)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        // 放在工具栏里时系统默认只显示图标
        .labelStyle(.titleAndIcon)
        .help("回到顶部")
    }
}
#endif
