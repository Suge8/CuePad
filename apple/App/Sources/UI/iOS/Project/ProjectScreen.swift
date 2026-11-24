#if os(iOS)
import CueStore
import SwiftUI

struct ProjectScreen: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @State private var data: ProjectPageData?
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    @State private var board = WallBoard()
    @State private var pane = Pane.work
    @State private var sessions: SessionListData?
    @State private var moreSessions = 0

    private enum Pane { case work, sessions }

    private struct Head: ViewModifier {
        let project: Project?
        let panes: AnyView?

        func body(content: Content) -> some View {
            let title = LocalizedStringResource.verbatim(project?.shownName ?? "")
            if let panes {
                content.floatingHeader(title, center: { panes }, trailing: { tools })
            } else {
                content.floatingHeader(title) {
                    if let project { ProjectActions(project: project, folders: false) }
                } detail: {
                } trailing: { tools }
            }
        }

        @ViewBuilder private var tools: some View {
            if let project { ProjectHeadTools(project: project, merged: panes != nil) }
        }
    }

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                if let data, board.arrangement != nil {
                    content(data)
                }
                Color.clear.frame(height: 0).debugScrollsToOlder(proxy, ready: board.arrangement != nil)
            }
        }
        .scrollPosition($position)
        .taskFoldScroll(anchor)
        .modifier(Head(project: project, panes: sizeClass == .compact && project != nil ? AnyView(panes) : nil))
        .compactFocus(open: data?.taskCounts.open ?? 0, shown: sizeClass == .regular && data?.tasks.isEmpty == false, position: $position)
        .observing(services.store, id: projectID, into: dataBinding, onError: workspace.fail) {
            [projectID] store in try ProjectPageData.read(projectID, from: store)
        }
        .observing(services.store, id: SessionListData.Key(filter: .init(text: "", project: projectID), limit: sessionLimit, moment: services.speech),
                   into: $sessions, onError: workspace.fail) { [projectID, limit = sessionLimit, moment = services.speech] store in
            try SessionListData.read(text: "", project: projectID, historyLimit: limit, at: moment, from: store)
        }
        .onDayChange { rearrange() }
    }

    private var sessionLimit: Int { ProjectSessions.cap + moreSessions }

    @ViewBuilder
    private func content(_ data: ProjectPageData) -> some View {
        // 任务区不进懒加载栈：在懒加载栈的一格里时，收起后按 id 滚回"收起"那一行会偏出一屏（`TaskFoldAnchor`）
        let paned = sizeClass == .compact && data.project != nil
        VStack(alignment: .leading, spacing: Spacing.part) {
            if paned, let project = data.project {
                ProjectBanner(project: project)
                name(project)
            }
            if paned, pane == .sessions {
                ProjectSessions(project: projectID, list: sessions, extra: $moreSessions)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ProjectSplit(project: paned ? nil : data.project, gap: Spacing.section) {
                    if data.project != nil { ProjectTasks(data: data, position: $position, anchor: anchor) }
                    ProjectWallSections(data: data, board: board)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion), value: data.tasks.roots.count)
        .padding(.horizontal, Spacing.page)
        .padding(.bottom, Spacing.section)
        .cardDragStage()
    }

    private var panes: some View {
        let live = (sessions?.pinned.count ?? 0) + (sessions?.now.count ?? 0)
        return PaneSegment(
            items: [.init(value: Pane.work, title: "内容"), .init(value: .sessions, title: "会话", badge: live)],
            selection: pane) { pane = $0 }
            .frame(height: FloatingHeaderLayout.height - PaneMetrics.inset * 2)
            .padding(PaneMetrics.inset)
            .glass(in: .capsule, interactive: true)
            .fixedSize()
            .dynamicTypeSize(...FloatingHeaderLayout.largestType)
            .modifier(YieldsToNotice())
    }

    private struct YieldsToNotice: ViewModifier {
        @Environment(Workspace.self) private var workspace

        func body(content: Content) -> some View {
            let hidden = workspace.noticeOnHead
            content.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).readerHidden(hidden)
                .animation(NoticeBanner.giveWay(hidden), value: hidden)
        }
    }

    private func name(_ project: Project) -> some View {
        Menu { ProjectActions(project: project, folders: false) } label: {
            HStack(spacing: Spacing.item) {
                ProjectGlyph(project: project, size: Glyph.projectIdentity)
                Text(verbatim: project.shownName).font(Typography.title).foregroundStyle(palette.ink).lineLimit(1)
                Chevron(.expand).foregroundStyle(palette.ink3)
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(.isHeader)
    }


    /// 名称、目录与计数取自项目目录，推入的第一帧就是最终值：导航栏标题在推入时定下，之后再换会让整页跳一下。
    private var project: Project? { workspace.catalog?.project(projectID) }

    private var dataBinding: Binding<ProjectPageData?> {
        Binding(get: { data }, set: { data = $0; rearrange() })
    }

    private func rearrange() {
        if let data { WallBoard.rearrange($board, with: data, project: projectID, reduceMotion: reduceMotion) }
    }
}
#endif
