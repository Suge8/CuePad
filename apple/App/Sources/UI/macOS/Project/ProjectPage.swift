#if os(macOS)
import CueStore
import SwiftUI

/// 项目页：页头（名称、介绍、目录与计数）→ 任务 → 资料 → 工作集卡片墙 → 更早。
struct ProjectPage: View {
    let projectID: UUID?
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

    /// 页头先到，其余每帧一段，自上而下。
    private enum Stage: Int, CaseIterable, Comparable {
        case header, focus, wall, older
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    private static let collapseOffset: CGFloat = 140
    /// 空项目那一行"添加任务"的宽度上限：只是一行输入，跟着内容，不铺满整页（下面的绑定引导与空态是纸，与页面同宽）。
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
        }
    }

    /// 页头（名称、目录、计数）取自项目目录，切换项目的第一帧就是新项目；卡片与任务读到后在其下出现。
    @ViewBuilder private var content: some View {
        let catalog = workspace.catalog
        if projectID == nil, catalog?.projects.isEmpty == true, (catalog?.cardCounts[nil] ?? 0) == 0 {
            Welcome()
        } else {
            VStack(alignment: .leading, spacing: Spacing.section) {
                ProjectHeader(
                    projectID: projectID, project: catalog?.project(projectID),
                    directory: projectID.flatMap { catalog?.directories[$0] }, cardCount: catalog?.cardCounts[projectID] ?? 0)
                if let data, let arrangement = board.arrangement, let shape { page(data, arrangement, shape) }
            }
            .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, 150)
        }
    }

    @ViewBuilder
    private func page(_ data: ProjectPageData, _ arrangement: WallArrangement, _ shape: PageShape) -> some View {
        let byID = shape.byID
        let lastTarget = shape.lastTarget
        if stage < .focus {
            EmptyView()
        } else if !data.tasks.isEmpty || data.taskCounts.done > 0 {
            // 没做完的都做完了也留着任务纸：纸底的"已完成"要能原地展开、点圆圈回到待办
            FocusBand(data: data, guide: workspace.folderGuide, position: $position, anchor: anchor)
        } else if let project = projectID {
            // 一条任务都没有：不画一个只装着空态的大框，收成一行添加任务；还没绑文件夹时接着写明并给一键绑（与任务区里同一个组件）
            VStack(alignment: .leading, spacing: 12) {
                NewTaskField(project: project).frame(maxWidth: Self.emptyLineWidth, alignment: .leading)
                if let project = data.project, !workspace.hasFolder(project.id) {
                    ProjectFolderGuide(project: project, guide: workspace.folderGuide, style: .panel)
                }
            }
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
            .paper(radius: 12)
        }
    }

    private func wallSection(title: String, count: Int, ids: [UUID], byID: [UUID: Card], lastTarget: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sectionTitle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Typography.sectionTitle).foregroundStyle(palette.ink)
                Text("\(count)").font(Typography.sectionCount).foregroundStyle(palette.ink3)
            }
            WallGrid(ids: ids, cards: byID, arrangedAt: board.arrangement?.arrangedAt) { card in
                CardTile(
                    card: card, lastTarget: lastTarget[card.id], floated: board.floated.contains(card.id))
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
        next.refresh(with: data, project: projectID)
        if next != board { board = next }
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

private struct ProjectHeader: View {
    let projectID: UUID?
    let project: Project?
    let directory: String?
    let cardCount: Int
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProjectGlyph(project: project, size: 20)
                    Text(projectID == nil ? CaptureCopy.unfiled : project?.name ?? "").font(Typography.pageTitle).foregroundStyle(palette.ink)
                }
                .contextMenu { if let project { ProjectActions(project: project) { workspace.projectForm = .init(project: project) } } }
                // 介绍回答"这是什么项目"，属于页头，不占任务栏的一栏
                if let intro = project?.intro {
                    Text(intro).font(Typography.lead).foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // 绑着文件夹时写路径（点它更换）；没绑时这里不说，"还没绑定文件夹"与一键绑只在任务区那一处
                HStack(spacing: 4) {
                    if let project, let directory {
                        DirectoryLink(path: Self.abbreviated(directory)) { workspace.chooseFolder(for: project) }
                        if cardCount > 0 { Dot() }
                    }
                    if cardCount > 0 { Text("\(cardCount) 条灵感").monospacedDigit() }
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
            }
            // 不再放"记一条灵感"：底部的输入栏与 ⌘N 就是入口
            Spacer()
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.hasPrefix(trimmed) ? "~" + path.dropFirst(trimmed.count) : path
    }
}

/// 项目页头部绑着的文件夹路径：点它更换，悬停有下划线、指针变手形。
private struct DirectoryLink: View {
    let path: String
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) { Text(path).underline(hovering) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .help("更换文件夹")
    }
}

private struct EmptyProject: View {
    let compact: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        EmptyIdeas(compact: compact, write: workspace.focusCapture).padding(.top, compact ? 0 : 48)
    }
}

/// 空库首次打开：共享的 EmptyLibrary（同 iOS 的图标与文案），动作是 Mac 的主按钮。
private struct Welcome: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        EmptyLibrary {
            // 不挂 ↩：弹出的项目表单里 ↩ 是"创建"，下面的页再挂一个会抢
            EmptyStateButton(title: "新建项目", systemImage: "folder.badge.plus", action: { workspace.projectForm = .init() })
        }
        .padding(.top, 160)
    }
}
#endif
