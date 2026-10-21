#if os(macOS)
import CueStore
import SwiftUI

/// 项目页：最上面一行次要字（介绍、目录与灵感条数，`ProjectLine`）→ 任务 → 资料 → 工作集卡片墙 → 更早。
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
    /// 空项目那一行"添加任务"的宽度上限：只是一行输入，跟着内容，不铺满整页（下面的空态是纸，与页面同宽）。
    private static let emptyLineWidth: CGFloat = 460

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    content.id("top")
                }
                .scrollPosition($position)
                .taskFoldScroll(anchor)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > Self.collapseOffset } action: { _, isCollapsed in
                    withAnimation(Motion.quick) { collapsed = isCollapsed }
                }
                // 下滚后收成的一行：浮在工具栏那一条里，但不放进工具栏——工具栏内容只随用户操作变，
                // 不随滚动位置这种布局读数变（工具栏一变就重排整个窗口，跟着滚动位置变会形成布局循环）
                if collapsed, let data, !data.tasks.isEmpty {
                    CompactFocus(data: data) {
                        withAnimation(Motion.spatial(Motion.panel, reduceMotion: reduceMotion)) { proxy.scrollTo("top", anchor: .top) }
                    }
                    .padding(.top, 8)
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .debugScrollsToOlder(proxy, ready: board.arrangement != nil)
        }
        // 批量选择的"全选"范围：看得见的这一页上散放的灵感（资料、墙、更早），按页上的顺序
        .onChange(of: SelectableKey(active: active, ids: board.arrangement.map { $0.pinned + $0.wall + $0.older }), initial: true) { _, key in
            if key.active, let ids = key.ids { workspace.presses.selectable = ids }
        }
        .observing(services.store, id: projectID, into: dataBinding, onError: workspace.fail) { [projectID] store in
            try ProjectPageData.read(projectID, from: store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rearrange() }
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

    /// 最上面那行（介绍、目录、条数）取自项目目录，切换项目的第一帧就是新项目；卡片与任务读到后在其下出现。
    @ViewBuilder private var content: some View {
        let catalog = workspace.catalog
        VStack(alignment: .leading, spacing: Spacing.sectionTitle) {
            ProjectLine(project: catalog?.project(projectID), directory: catalog?.directories[projectID], cardCount: catalog?.cardCounts[projectID] ?? 0)
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let data, let arrangement = board.arrangement, let shape { page(data, arrangement, shape) }
            }
        }
        .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, 150)
    }

    @ViewBuilder
    private func page(_ data: ProjectPageData, _ arrangement: WallArrangement, _ shape: PageShape) -> some View {
        let byID = shape.byID
        let lastTarget = shape.lastTarget
        if stage < .focus {
            EmptyView()
        } else if !data.tasks.isEmpty || data.taskCounts.done > 0 {
            // 没做完的都做完了也留着任务纸：纸底的"已完成"要能原地展开、点圆圈回到待办
            FocusBand(data: data, position: $position, anchor: anchor)
        } else {
            // 一条任务都没有：不画一个只装着空态的大框，收成一行添加任务
            NewTaskField(project: projectID).frame(maxWidth: Self.emptyLineWidth, alignment: .leading)
        }
        if stage >= .wall {
            if data.cards.isEmpty {
                EmptyProject(compact: !data.tasks.isEmpty)
            } else {
                if !arrangement.pinned.isEmpty { resources(arrangement.pinned.compactMap { byID[$0] }, lastTarget: lastTarget) }
                if !arrangement.wall.isEmpty {
                    wallSection(title: "最近", count: arrangement.wall.count, ids: arrangement.wall, byID: byID, lastTarget: lastTarget)
                }
                if stage >= .older, !arrangement.older.isEmpty {
                    OlderList(groups: shape.older, cards: byID, lastTarget: lastTarget)
                }
            }
        }
    }

    /// 资料：长期参考的灵感，一行一条压在任务区下面。
    private func resources(_ cards: [Card], lastTarget: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sectionTitle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("资料").font(Typography.sectionTitle).foregroundStyle(palette.ink)
                Text("\(cards.count)").font(Typography.sectionCount).foregroundStyle(palette.ink3)
            }
            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    if index > 0 { Rectangle().fill(palette.hair).frame(height: 1).padding(.leading, 40) }
                    OlderRow(card: card, lastTarget: lastTarget[card.id])
                }
            }
            .rowPaper(radius: 12)
        }
    }

    private func wallSection(title: String, count: Int, ids: [UUID], byID: [UUID: Card], lastTarget: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sectionTitle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Typography.sectionTitle).foregroundStyle(palette.ink)
                Text("\(count)").font(Typography.sectionCount).foregroundStyle(palette.ink3)
            }
            MasonryLayout(minColumnWidth: Self.minColumnWidth, maxColumns: Self.maxColumns, spacing: Self.wallSpacing) {
                ForEach(ids.compactMap { byID[$0] }) { card in
                    CardTile(card: card, lastTarget: lastTarget[card.id], floated: board.floated.contains(card.id))
                        .transition(Motion.item)
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
            withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) { board = next }
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
    let lastTarget: [UUID: String]
    let older: [OlderGroup]

    init(_ data: ProjectPageData, _ arrangement: WallArrangement) {
        byID = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0) })
        lastTarget = data.lastTarget
        older = data.olderGroups(arrangement)
    }
}

/// 项目页最上面的一行次要字：介绍（一行，截断时悬停看全文）· 项目在这台 Mac 上的文件夹（绑着的写路径，带"在访达中显示"；
/// 没绑的写开工时会建好的工作区）与"换文件夹…" · 几条灵感。路径写短（`Workspaces.shown`，悬停看全路径）：它说的是活在哪干，
/// 一眼认得出就够，不收进菜单。
private struct ProjectLine: View {
    let project: Project?
    /// 这台 Mac 上绑着的文件夹；没绑为 nil。
    let directory: String?
    let cardCount: Int
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            if let intro = project?.intro {
                Text(intro).foregroundStyle(palette.ink2).lineLimit(1).truncationMode(.tail).help(intro).textSelection(.enabled)
                Dot()
            }
            if let project { folder(project).layoutPriority(1) }
            if cardCount > 0 {
                Dot()
                Text("\(cardCount) 条灵感").monospacedDigit().layoutPriority(1)
            }
        }
        .font(Typography.secondary).foregroundStyle(palette.ink3)
    }

    private func folder(_ project: Project) -> some View {
        let path = directory ?? services.workspaces.directory(for: project.name).path(percentEncoded: false)
        return HStack(spacing: 8) {
            Label(services.workspaces.shown(path), icon: .folder).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .help(directory == nil ? "第一次在这台 Mac 上开工时建好" : path)
            if let directory {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)]) }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
            } else {
                Text("开工时建好").lineLimit(1)
            }
            Button("换文件夹…") { workspace.chooseFolder(for: project) }
                .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
        }
    }
}

private struct EmptyProject: View {
    let compact: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        EmptyIdeas(compact: compact, write: workspace.focusCapture, speak: { workspace.show(.cue) }).padding(.top, compact ? 0 : 48)
    }
}

#endif
