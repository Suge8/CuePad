#if os(macOS)
import CueStore
import SwiftUI

struct ProjectPage: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    @State private var data: ProjectPageData?
    @State private var board = WallBoard()
    @State private var collapsed = false
    @Environment(\.topBand) private var band
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    /// 首次挂上时内容分几帧出（`Stage`）：一个回合里全建要几十毫秒；留着的页回来时已经在最后一段。
    @State private var stage = Stage.header

    private enum Stage: Int, CaseIterable, Comparable {
        case header, focus, wall, older
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    private static let collapseOffset: CGFloat = 140
    /// 卡片墙：列不窄于 260；2560 宽的全屏收起侧栏是 9 列，留出余量。
    private static let metrics = ProjectWallSections<CardTile>.Metrics(
        minColumnWidth: 260, maxColumns: 12, wallSpacing: 16, sectionGap: Spacing.section, headerGap: Spacing.group, olderGap: Spacing.page)

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    content.id("top")
                }
                .scrollPosition($position)
                .taskFoldScroll(anchor)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > Self.collapseOffset } action: { _, isCollapsed in
                    withAnimation(Motion.fade) { collapsed = isCollapsed }
                }
                // 下滚后的回到顶部是页里的一块、不放进栏头：栏头内容只随用户操作变，不随滚动位置这种布局读数变（跟着滚动位置变会形成布局循环）。
                if collapsed, let data, !data.tasks.isEmpty {
                    CompactFocus(data: data) {
                        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo("top", anchor: .top) }
                    }
                    .frame(height: band)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
                }
            }
            .debugScrollsToOlder(proxy, ready: board.arrangement != nil)
        }
        .onChange(of: SelectableKey(active: active, ids: board.arrangement.map { $0.pinned + $0.wall + $0.older }), initial: true) { _, key in
            if key.active, let ids = key.ids { workspace.presses.selectable = ids }
        }
        .observing(services.store, id: projectID, into: dataBinding, onError: workspace.fail) { [projectID] store in
            try ProjectPageData.read(projectID, from: store)
        }
        .onDayChange { rearrange() }
        .task(id: board.arrangement != nil) {
            guard board.arrangement != nil else { return }
            for next in Stage.allCases where next > stage {
                await NextFrame.wait()
                stage = next
            }
            // 首屏有了（`interact` 等它）：按页面排完记，不按墙上的卡片出现——没有"最近"卡片的项目（演示库的圆桌）永远等不到
            DebugHooks.mark("content")
        }
    }

    /// 最上面那行取自项目目录，切换项目的第一帧就是新项目；卡片与任务读到后在其下出现。
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            ProjectIntroLine(project: workspace.catalog?.project(projectID), intro: false)
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let data, let arrangement = board.arrangement { page(data, arrangement) }
            }
        }
        .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, CaptureBar.clearance)
        .cardDragStage()
    }

    @ViewBuilder
    private func page(_ data: ProjectPageData, _ arrangement: WallArrangement) -> some View {
        if stage >= .focus { FocusBand(data: data, position: $position, anchor: anchor) }
        if stage >= .wall {
            ProjectWallSections(
                data: data, arrangement: arrangement, older: board.older, metrics: Self.metrics, showsOlder: stage >= .older
            ) { entry in
                CardTile(card: entry.card, lastTarget: data.lastTarget[entry.id], floated: board.floated.contains(entry.id))
            }
        }
    }

    /// 读到的数据与由它推出的分区、墙与"更早"在同一次写入里落下：页面只多算一遍，不先露一帧只有页头的样子。
    private var dataBinding: Binding<ProjectPageData?> {
        Binding(get: { data }, set: { data = $0; rearrange() })
    }

    private func rearrange() {
        if let data { WallBoard.rearrange($board, with: data, project: projectID, reduceMotion: reduceMotion) }
    }
}

private struct SelectableKey: Equatable {
    let active: Bool
    let ids: [UUID]?
}

#endif
