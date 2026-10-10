#if os(macOS)
import CueStore
import SwiftUI

/// 项目页：页头（名称、介绍、目录与计数）→ 任务与 Agent → 资料 → 工作集卡片墙 → 更早。
struct ProjectPage: View {
    let projectID: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data: ProjectPageData?
    @State private var agents: AgentLinks?
    @State private var folderGuide: FolderGuide?
    @State private var sessions: ProjectSessions?
    @State private var board = WallBoard()
    @State private var collapsed = false

    private static let collapseOffset: CGFloat = 140
    /// 空项目那一行"添加任务"的宽度上限：只是一行输入，跟着内容，不铺满整页（下面的绑定引导与空态是纸，与页面同宽）。
    private static let emptyLineWidth: CGFloat = 460

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    content.id("top")
                }
                .fadesUnderBars()
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > Self.collapseOffset } action: { _, isCollapsed in
                    withAnimation(Motion.quick) { collapsed = isCollapsed }
                }
                // 下滚后收成的一行：浮在工具栏那一条里，但不放进工具栏——工具栏内容只随用户操作变，
                // 不随滚动位置这种布局读数变（工具栏一变就重排整个窗口，跟着滚动位置变会形成布局循环）
                if collapsed, let data, showsFocus(data) {
                    CompactFocus(data: data, agents: projectAgents) {
                        withAnimation(Motion.spatial(Motion.panel, reduceMotion: reduceMotion)) { proxy.scrollTo("top", anchor: .top) }
                    }
                    .padding(.top, 8)
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            #if DEBUG
            .onChange(of: board.arrangement != nil) { DebugScene.scrollIfNeeded(proxy) }
            #endif
        }
        .environment(\.cardAgents, agents ?? AgentLinks(items: [:], launching: []))
        .observing(services.store, AgentLinks.tables, into: $agents, onError: workspace.fail) { try AgentLinks.read(from: $0) }
        .observingFolderGuide(into: $folderGuide)
        .observing(services.store, ProjectSessions.tables, id: projectID, into: $sessions, onError: workspace.fail) { [projectID] store in
            try projectID.map { try ProjectSessions.read($0, from: store) } ?? ProjectSessions(recorded: [], deliveries: [:], undelivered: [:], bindings: [])
        }
        .observing(services.store, [.cards, .projects, .sendRecords], id: projectID, into: $data, onError: workspace.fail) { [projectID] store in
            try ProjectPageData.read(projectID, from: store)
        }
        .onChange(of: data?.stamps()) { rearrange() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rearrange() }
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
                if let data, let arrangement = board.arrangement { page(data, arrangement) }
            }
            .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, 150)
        }
    }

    @ViewBuilder
    private func page(_ data: ProjectPageData, _ arrangement: WallArrangement) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0) })
        let lastTarget = data.lastTarget
        if showsFocus(data) {
            FocusBand(data: data, agents: projectAgents, guide: folderGuide)
        } else if let project = projectID {
            // 两边都空：不画一个只装着空态的大框，收成一行添加任务；还没绑文件夹时接着写明并给一键绑（与 Agent 栏同一个组件）
            VStack(alignment: .leading, spacing: 12) {
                NewTaskField(project: project).frame(maxWidth: Self.emptyLineWidth, alignment: .leading)
                if let project = data.project, !workspace.hasFolder(project.id) {
                    ProjectFolderGuide(project: project, guide: folderGuide, style: .panel)
                }
            }
        }
        if data.cards.isEmpty {
            EmptyProject(compact: showsFocus(data))
        } else {
            if !arrangement.pinned.isEmpty { resources(arrangement.pinned.compactMap { byID[$0] }, lastTarget: lastTarget) }
            if !arrangement.wall.isEmpty {
                wallSection(title: "最近", count: arrangement.wall.count, ids: arrangement.wall, byID: byID, lastTarget: lastTarget)
            }
            if !arrangement.older.isEmpty {
                OlderList(
                    groups: data.olderGroups(arrangement),
                    cards: byID, lastTarget: lastTarget)
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

    /// 有任务或本项目的在线会话（本机的与别的 Mac 上的）时才有"任务与 Agent"一栏；两边都空时项目页只留一行添加任务。
    private func showsFocus(_ data: ProjectPageData) -> Bool {
        !data.tasks.isEmpty || !projectAgents.isEmpty
    }

    private var projectAgents: [ProjectAgents.Row] { workspace.projectAgents(projectID, synced: sessions) }

    private func rearrange() {
        guard let data else { return }
        board.refresh(with: data, project: projectID)
    }
}

private struct ProjectHeader: View {
    let projectID: UUID?
    let project: Project?
    let directory: String?
    let cardCount: Int
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var renaming: Project?

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProjectGlyph(project: project, size: 20)
                    Text(projectID == nil ? "未分类" : project?.name ?? "").font(Typography.pageTitle).foregroundStyle(palette.ink)
                }
                .contextMenu { if let project { ProjectActions(project: project) { renaming = project } } }
                // 介绍回答"这是什么项目"，属于页头，不占任务栏的一栏
                if let intro = project?.intro {
                    Text(intro).font(Typography.lead).foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // 绑着文件夹时写路径（点它更换）；没绑时这里不说，"还没绑定文件夹"与一键绑只在任务与 Agent 那一处
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
        .sheet(item: $renaming) { ProjectForm(project: $0) }
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
    @State private var creating = false

    var body: some View {
        EmptyLibrary {
            EmptyStateButton(title: "新建项目", systemImage: "folder.badge.plus", action: { creating = true })
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 160)
        .sheet(isPresented: $creating) { ProjectForm(project: nil) }
    }
}
#endif
