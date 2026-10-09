#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 任务与 Agent：本项目任务（"任务 完成数/总数"，前几条顶层任务连同子任务，可拖动、缩进，同任务面板）+ 本项目的 Agent 会话。介绍在页头。
struct FocusBand: View {
    let data: ProjectPageData
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static let visibleTasks = 4
    /// 窄于这个宽度时两栏改成上下排，每栏都能放下一整行任务。
    private static let stackedBelow: CGFloat = 640

    var body: some View {
        // 由排版当场选：横排的理想宽度钉在 stackedBelow，放得下就横排，否则上下排。不读几何、不写状态
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                column { tasks }
                divider
                column { PiColumn(project: data.project) }
                    .frame(maxWidth: 300)
            }
            .frame(minWidth: Self.stackedBelow, idealWidth: Self.stackedBelow, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                column { tasks }
                Divider().overlay(palette.hair).padding(.horizontal, 18)
                column { PiColumn(project: data.project) }
            }
        }
        .paper(radius: 18)
        // 任务上的会话状态点开是它的详情（与侧栏、⌘K、任务面板同一个详情弹出层）
    }

    @ViewBuilder private var tasks: some View {
        SectionLabel(text: data.taskProgress.map { "任务 \($0.done)/\($0.total)" } ?? "任务", systemImage: "checklist")
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

/// 本项目正在跑的 Pi 会话。
private struct PiColumn: View {
    /// 未分类没有项目，也就没有文件夹可绑。
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        SectionLabel(text: "Agent", systemImage: "terminal")
        let sessions = workspace.liveSessions(in: project?.id)
        if sessions.isEmpty {
            if let project, !workspace.hasFolder(project.id) {
                ProjectFolderGuide(project: project, style: .inset)
            } else {
                Text("没有运行中的会话").font(Typography.secondary).foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(sessions) { session in
            PiSessionRow(
                session: .live(session, hostID: workspace.services.hostID, projectID: project?.id, recap: workspace.sessionRecaps[session.sessionID]),
                project: project, delivery: workspace.sessionDeliveries[session.sessionID])
        }
    }
}

/// 下滚后收成的悬浮标题：一块玻璃写项目名、任务完成数/总数与 Agent 状态；点一下回到顶部。
struct CompactFocus: View {
    let data: ProjectPageData
    let scrollToTop: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let session = workspace.liveSessions(in: data.project?.id).first
        Button(action: scrollToTop) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ProjectGlyph(project: data.project, size: 13)
                    Text(data.project?.name ?? CaptureCopy.inbox).font(Typography.toolbarTitle).lineLimit(1)
                }
                Label(data.taskProgress.map { "任务 \($0.done)/\($0.total)" } ?? "任务", systemImage: "checklist").foregroundStyle(palette.ink2)
                if let session {
                    let shown = workspace.shown(session)
                    HStack(spacing: 6) {
                        PiStateDot(shown: shown, size: 5)
                        Text("\(session.displayName) \(shown.label)")
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
