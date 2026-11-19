#if os(iOS)
import CueStore
import SwiftUI

struct ProjectScreen: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.palette) private var palette
    @State private var data: ProjectPageData?
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    @State private var board = WallBoard()
    @State private var pane = Pane.work
    @State private var sessions: SessionListData?
    @State private var moreSessions = 0

    /// 手机没有会话条里项目下面那几行，这个项目的会话在这一页的另一段里。只点按切换、不认左右滑：任务行左滑是它的操作，从屏边右滑是返回。
    private enum Pane { case work, sessions }

    /// 手机：页头正中是那两段（同项目列表页头的"项目 / 进展"），项目名与它的菜单在封面下面（`name`）。宽屏在栏头（`WideColumnHead`），这里给的只是标题。
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
                if let data, let arrangement = board.arrangement {
                    content(data, arrangement)
                }
                Color.clear.frame(height: 0).debugScrollsToOlder(proxy, ready: board.arrangement != nil)
            }
        }
        .scrollPosition($position)
        .taskFoldScroll(anchor)
        .modifier(Head(project: project, panes: sizeClass == .compact && project != nil ? AnyView(panes) : nil))
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
    private func content(_ data: ProjectPageData, _ arrangement: WallArrangement) -> some View {
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
                ProjectSplit(project: paned ? nil : data.project, gap: Self.sectionGap) {
                    if data.project != nil { ProjectTasks(data: data, position: $position, anchor: anchor) }
                    ProjectWallSections(data: data, arrangement: arrangement, older: board.older, metrics: metrics) { entry in
                        CardTileView(entry: entry, floated: board.floated.contains(entry.id))
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        // 添一条、做完一条：新行淡入，下面的行与灵感墙滑着让位，不是整页往下一跳。按条数不按顺序：拖动排序自己带着动画
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

    /// 提示盖在页头正中时这两段让开、不接点按（同项目列表页头的那两段，`NarrowSidebarBar`）。单独一个视图：提示来去只重算它，不重算整页。
    private struct YieldsToNotice: ViewModifier {
        @Environment(Workspace.self) private var workspace

        func body(content: Content) -> some View {
            let hidden = workspace.noticeOnHead
            content.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).readerHidden(hidden)
                .animation(NoticeBanner.giveWay(hidden), value: hidden)
        }
    }

    /// 封面下面的项目名，同项目列表那张卡上的图标与名字；点开是这个项目自己的操作。
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

    private static let sectionGap = Spacing.section

    /// 卡片墙：辅助字号下只排一列，卡上的字与"添加灵感"才不被窄列挤成一字一行。
    private var metrics: ProjectWallSections<CardTileView>.Metrics {
        .init(minColumnWidth: sizeClass == .regular ? 220 : 150, maxColumns: typeSize.isAccessibilitySize ? 1 : 4, wallSpacing: 12,
              sectionGap: Self.sectionGap, olderGap: 8)
    }

    /// 名称、目录与计数取自项目目录，推入的第一帧就是最终值：导航栏标题在推入时定下，之后再换会让整页跳一下。
    private var project: Project? { workspace.catalog?.project(projectID) }

    /// 读到的数据与由它推出的分区在同一次写入里落下（同 Mac 的 `ProjectPage`）。
    private var dataBinding: Binding<ProjectPageData?> {
        Binding(get: { data }, set: { data = $0; rearrange() })
    }

    private func rearrange() {
        if let data { WallBoard.rearrange($board, with: data, project: projectID, reduceMotion: reduceMotion) }
    }
}
#endif
