#if os(macOS)
import CueStore
import SwiftUI

/// 项目页（与手机项目页同构）：最上面一行项目的一句介绍接它的文件夹（`ProjectIntroLine`）→ 任务那张纸（`FocusBand`）→ 置顶的灵感 → 工作集卡片墙 → 更早；一条灵感都没有时墙上只有说现状的那一格（`EmptyWallTile`，记灵感在底部随手记）。
/// 不写项目名作大标题：侧栏开着时名字就在选中的那一行，收起时工具栏的切换胶囊写它（`ProjectSwitcher`）。
struct ProjectPage: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    @State private var data: ProjectPageData?
    @State private var board = WallBoard()
    /// 墙与"更早"要用的、由数据和分区推出的东西：数据或分区变了才重算（任务行里 Agent 的状态一变页面就要重算，每次都从上千张卡里重新分组太贵）。
    @State private var shape: PageShape?
    @State private var collapsed = false
    /// 窗口最顶那一排的高（`readsTopBand`）：下滚后的回到顶部排在那一排里。
    @State private var band: CGFloat = 0
    /// 任务纸收起其余任务时连带的滚动（`TaskFoldAnchor`）。
    @State private var position = ScrollPosition()
    @State private var anchor = TaskFoldAnchor()
    /// 首次挂上时内容分几帧出（`Stage`）：一个回合里全建要几十毫秒；留着的页回来时已经在最后一段。
    @State private var stage = Stage.header

    /// 最上面那行先到，其余每帧一段，自上而下。
    private enum Stage: Int, CaseIterable, Comparable {
        case header, focus, wall, older
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    private static let collapseOffset: CGFloat = 140
    /// 卡片墙：列不窄于 260；2560 宽的全屏收起侧栏是 9 列，留出余量。
    private static let minColumnWidth: CGFloat = 260
    private static let maxColumns = 12
    private static let wallSpacing: CGFloat = 16

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
                // 下滚后的回到顶部：排进窗口最顶那一排、居中（项目页那一排中间是空的），不压在下一排的卡片上；
                // 是页里的一块、不放进工具栏——工具栏内容只随用户操作变，不随滚动位置这种布局读数变（工具栏一变就重排整个窗口，跟着滚动位置变会形成布局循环）
                if collapsed, let data, !data.tasks.isEmpty {
                    CompactFocus(data: data) {
                        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo("top", anchor: .top) }
                    }
                    .frame(height: band)
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
                }
            }
            .readsTopBand(into: $band)
            .debugScrollsToOlder(proxy, ready: board.arrangement != nil)
        }
        // 批量选择的"全选"范围：看得见的这一页上散放的灵感（置顶、墙、更早），按页上的顺序
        .onChange(of: SelectableKey(active: active, ids: board.arrangement.map { $0.pinned + $0.wall + $0.older }), initial: true) { _, key in
            if key.active, let ids = key.ids { workspace.presses.selectable = ids }
        }
        .observing(services.store, id: projectID, into: dataBinding, onError: workspace.fail) { [projectID] store in
            try ProjectPageData.read(projectID, from: store)
        }
        .onDayChange { rearrange() }
        .task(id: shape != nil) {
            guard shape != nil else { return }
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
        VStack(alignment: .leading, spacing: Spacing.sectionTitle) {
            ProjectIntroLine(project: workspace.catalog?.project(projectID))
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let data, let arrangement = board.arrangement, let shape { page(data, arrangement, shape) }
            }
        }
        .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, 150)
    }

    @ViewBuilder
    private func page(_ data: ProjectPageData, _ arrangement: WallArrangement, _ shape: PageShape) -> some View {
        let byID = shape.byID
        let lastTarget = data.lastTarget
        if stage >= .focus { FocusBand(data: data, position: $position, anchor: anchor) }
        if stage >= .wall {
            if data.cards.isEmpty {
                MasonryLayout(minColumnWidth: Self.minColumnWidth, maxColumns: Self.maxColumns, spacing: Self.wallSpacing) {
                    EmptyWallTile()
                }
            } else {
                if !arrangement.pinned.isEmpty { pinned(arrangement.pinned.compactMap { byID[$0] }, lastTarget: lastTarget) }
                if !arrangement.wall.isEmpty {
                    wallSection(title: "最近", count: arrangement.wall.count, ids: arrangement.wall, byID: byID, lastTarget: lastTarget)
                }
                if stage >= .older, !arrangement.older.isEmpty {
                    OlderList(groups: shape.older, cards: byID, lastTarget: lastTarget)
                }
            }
        }
    }

    /// 置顶的灵感：长期参考的，一行一条压在任务纸下面；不另起组名，行首的图钉认得出。
    private func pinned(_ cards: [Card], lastTarget: [UUID: String]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 { Rectangle().fill(palette.hair).frame(height: 1).padding(.leading, 40) }
                OlderRow(card: card, lastTarget: lastTarget[card.id], pinned: true)
            }
        }
        .rowPaper(cornerRadius: Radius.block)
    }

    private func wallSection(title: LocalizedStringResource, count: Int, ids: [UUID], byID: [UUID: Card], lastTarget: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sectionTitle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Typography.sectionTitle).foregroundStyle(palette.ink)
                Text("\(count)").font(Typography.sectionCount).foregroundStyle(palette.ink3)
            }
            MasonryLayout(minColumnWidth: Self.minColumnWidth, maxColumns: Self.maxColumns, spacing: Self.wallSpacing) {
                ForEach(ids.compactMap { byID[$0] }) { card in
                    CardTile(card: card, lastTarget: lastTarget[card.id], floated: board.floated.contains(card.id))
                        .transition(.opacity)
                }
            }
        }
    }

    /// 读到的数据与由它推出的分区、墙与"更早"在同一次写入里落下：页面只多算一遍，不先露一帧只有页头的样子。
    private var dataBinding: Binding<ProjectPageData?> {
        Binding(get: { data }, set: { data = $0; rearrange() })
    }

    private func rearrange() {
        guard let data else { return }
        var next = board
        // 第一次排墙直接到位；之后墙上的卡增减、挪位有动画（同手机项目页）
        if next.refresh(with: data, project: projectID) {
            board = next
        } else if next != board {
            withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { board = next }
        }
        if let arrangement = next.arrangement {
            let shape = PageShape(data, arrangement)
            if shape != self.shape { self.shape = shape }
        }
    }
}

private struct SelectableKey: Equatable {
    let active: Bool
    let ids: [UUID]?
}

private struct PageShape: Equatable {
    let byID: [UUID: Card]
    let older: [OlderGroup]

    init(_ data: ProjectPageData, _ arrangement: WallArrangement) {
        byID = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0) })
        older = data.olderGroups(arrangement)
    }
}

#endif
