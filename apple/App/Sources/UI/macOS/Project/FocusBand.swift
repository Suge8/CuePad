#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 介绍与任务：项目的一句话介绍 + 本项目任务（"任务 完成数/总数"，前几条顶层任务连同子任务，可拖动、缩进，同任务面板）+ 本项目的 Pi 会话。没写介绍时不显示介绍一栏。
struct FocusBand: View {
    let data: ProjectPageData
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static let visibleTasks = 4
    /// 窄于这个宽度时三栏改成上下排，每栏都能放下一整行任务。
    private static let stackedBelow: CGFloat = 820

    var body: some View {
        // 由排版当场选：横排的理想宽度钉在 stackedBelow，放得下就横排，否则上下排。不读几何、不写状态
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                if let intro = data.project?.intro {
                    column { introColumn(intro) }
                    divider
                }
                column { tasks }
                divider
                column { PiColumn(project: data.project?.id, hasDirectory: data.project.flatMap { workspace.catalog?.directories[$0.id] } != nil) }
                    .frame(maxWidth: 300)
            }
            .frame(minWidth: Self.stackedBelow, idealWidth: Self.stackedBelow, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                if let intro = data.project?.intro {
                    column { introColumn(intro) }
                    Divider().overlay(palette.hair).padding(.horizontal, 18)
                }
                column { tasks }
                Divider().overlay(palette.hair).padding(.horizontal, 18)
                column { PiColumn(project: data.project?.id, hasDirectory: data.project.flatMap { workspace.catalog?.directories[$0.id] } != nil) }
            }
        }
        .paper(radius: 18)
        // 任务上的会话状态点开是它的详情（与侧栏、⌘K、任务面板同一个详情弹出层）
        .modifier(SessionDetailHost(arrowEdge: .bottom))
    }

    @ViewBuilder private func introColumn(_ intro: String) -> some View {
        SectionLabel(text: "介绍", systemImage: "text.quote")
        Text(intro).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
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
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.ink3)
            }
            NewTaskField(project: data.project?.id)
        }
    }

    private var divider: some View {
        Rectangle().fill(palette.hair).frame(width: 1).padding(.vertical, 14)
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 本项目正在跑的 Pi 会话。
private struct PiColumn: View {
    let project: UUID?
    let hasDirectory: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        SectionLabel(text: "Agent", systemImage: "terminal")
        let sessions = workspace.liveSessions(in: project)
        if sessions.isEmpty {
            Text(hasDirectory ? "没有运行中的会话" : "还没绑定代码目录")
                .font(.system(size: 12.5)).foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(sessions) { session in
            PiSessionRow(
                session: .live(session, hostID: workspace.services.hostID, projectID: project, recap: workspace.sessionRecaps[session.sessionID]),
                project: workspace.catalog?.project(project), delivery: workspace.sessionDeliveries[session.sessionID],
                nameFont: .system(size: 13, weight: .semibold), lineFont: .system(size: 12), dotSize: 5)
        }
    }
}

/// 下滚后收成的一行：介绍（有才显示）· 任务完成数/总数 · Pi 状态；点一下回到顶部。
struct CompactFocus: View {
    let data: ProjectPageData
    let scrollToTop: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let intro = data.project?.intro
        let session = workspace.liveSessions(in: data.project?.id).first
        Button(action: scrollToTop) {
            HStack(spacing: 14) {
                if let intro { Label(intro, systemImage: "text.quote").lineLimit(1) }
                Label(data.taskProgress.map { "任务 \($0.done)/\($0.total)" } ?? "任务", systemImage: "checklist").foregroundStyle(palette.ink2)
                if let session {
                    HStack(spacing: 6) {
                        PiStateDot(state: session.state.work, size: 5)
                        Text("\(session.displayName) \(session.state.work.label)")
                    }
                    .foregroundStyle(palette.ink2)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 16).frame(height: 34)
            .paper(radius: 17, lifted: true)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        // 放在工具栏里时系统默认只显示图标
        .labelStyle(.titleAndIcon)
        .help("回到顶部")
    }
}
#endif
