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
    @State private var data: ProjectPageData?
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    @State private var board = WallBoard()

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
        .floatingHeader(.verbatim(project?.shownName ?? "")) {
            if let project { ProjectActions(project: project, folders: false) }
        } detail: {
        } trailing: {
            if let project { ProjectHeadTools(project: project) }
        }
        .observing(services.store, id: projectID, into: dataBinding, onError: workspace.fail) {
            [projectID] store in try ProjectPageData.read(projectID, from: store)
        }
        .onDayChange { rearrange() }
    }

    @ViewBuilder
    private func content(_ data: ProjectPageData, _ arrangement: WallArrangement) -> some View {
        let lastTarget = data.lastTarget
        // 任务区不进懒加载栈：在懒加载栈的一格里时，收起后按 id 滚回"收起"那一行会偏出一屏（`TaskFoldAnchor`）
        ProjectSplit(gap: Self.sectionGap) {
            if data.project != nil { ProjectTasks(data: data, position: $position, anchor: anchor) }
            ProjectWallSections(data: data, arrangement: arrangement, older: board.older, metrics: metrics) { entry in
                CardTileView(entry: entry, lastTarget: lastTarget[entry.id], floated: board.floated.contains(entry.id))
            }
        }
        .padding(.horizontal, Spacing.page)
        .padding(.bottom, Spacing.section)
        .cardDragStage()
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
