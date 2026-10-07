#if os(macOS)
import CueStore
import SwiftUI

/// 项目页：目标与下一步 → 工作集卡片墙（置顶单列在前）→ 更早。
struct ProjectPage: View {
    let projectID: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data: ProjectPageData?
    @State private var board = WallBoard()
    @State private var collapsed = false

    private static let collapseOffset: CGFloat = 140

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    content.id("top")
                }
                .overlay { BottomFade() }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > Self.collapseOffset } action: { _, isCollapsed in
                    withAnimation(Motion.quick) { collapsed = isCollapsed }
                }
                TopFade()
                // 下滚后收成的一行：在顶部渐隐之上、工具栏那一条里，但不放进工具栏——工具栏内容只随用户操作变，
                // 不随滚动位置这种布局读数变（工具栏一变就重排整个窗口，跟着滚动位置变会形成布局循环）
                if collapsed, let data, showsFocus(data) {
                    CompactFocus(data: data) {
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
            VStack(alignment: .leading, spacing: 28) {
                ProjectHeader(
                    projectID: projectID, project: catalog?.project(projectID),
                    directory: projectID.flatMap { catalog?.directories[$0] }, cardCount: catalog?.cardCounts[projectID] ?? 0)
                if let data, let arrangement = board.arrangement { page(data, arrangement) }
            }
            .padding(.horizontal, 32).padding(.top, 6).padding(.bottom, 150)
        }
    }

    @ViewBuilder
    private func page(_ data: ProjectPageData, _ arrangement: WallArrangement) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0) })
        let lastTarget = data.lastTarget
        if showsFocus(data) { FocusBand(data: data) }
        if data.cards.isEmpty {
            EmptyProject()
        } else {
            if !arrangement.pinned.isEmpty { resources(arrangement.pinned.compactMap { byID[$0] }, lastTarget: lastTarget) }
            if !arrangement.wall.isEmpty {
                wallSection(title: "最近", count: arrangement.wall.count, ids: arrangement.wall, byID: byID, data: data, lastTarget: lastTarget)
            }
            if !arrangement.older.isEmpty {
                OlderList(
                    groups: data.olderGroups(arrangement),
                    cards: byID, lastTarget: lastTarget)
            }
        }
    }

    /// 资料：长期参考的灵感，一行一条压在任务区下面；交给 Agent 时可一并带上。
    private func resources(_ cards: [Card], lastTarget: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 6) {
                Text("资料").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink2)
                Text("\(cards.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(palette.ink3)
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

    private func wallSection(title: String, count: Int, ids: [UUID], byID: [UUID: Card], data: ProjectPageData, lastTarget: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink2)
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(palette.ink3)
            }
            WallGrid(ids: ids, cards: byID, arrangedAt: board.arrangement?.arrangedAt) { card in
                CardTile(
                    card: card, lastTarget: lastTarget[card.id], floated: board.floated.contains(card.id))
            }
        }
    }

    /// 有目标卡、未完成任务或本项目的 Pi 会话之一就显示；缺的那一栏各自隐藏。
    private func showsFocus(_ data: ProjectPageData) -> Bool {
        data.project?.intro != nil || !data.tasks.isEmpty || !workspace.liveSessions(in: projectID).isEmpty
    }

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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ProjectGlyph(project: project, size: 20)
                    Text(projectID == nil ? "未归档" : project?.name ?? "").font(.system(size: 28, weight: .bold)).foregroundStyle(palette.ink)
                }
                .contextMenu { if let project { ProjectMenu(project: project) { renaming = project } } }
                HStack(spacing: 4) {
                    if let project {
                        DirectoryLink(path: directory.map(Self.abbreviated)) {
                            ProjectDirectory.choose(for: project.id, workspace: workspace)
                        }
                        if cardCount > 0 { Text("·") }
                    }
                    if cardCount > 0 { Text("\(cardCount) 条灵感").monospacedDigit() }
                }
                .font(.system(size: 12)).foregroundStyle(palette.ink3)
            }
            Spacer()
            NewCardButton(project: projectID)
        }
        .sheet(item: $renaming) { ProjectForm(project: $0) }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.hasPrefix(trimmed) ? "~" + path.dropFirst(trimmed.count) : path
    }
}

struct NewCardButton: View {
    let project: UUID?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("记一条灵感", systemImage: "plus") {
            let project = project
            workspace.attempt { workspace.openCard = try await workspace.createCard(in: project).id }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .help("记一条灵感（⌘N）")
    }
}

/// 项目页头部的代码目录：没绑定时是带图标的"绑定代码目录…"，绑定后是路径；都可点，悬停有下划线、指针变手形。
private struct DirectoryLink: View {
    let path: String?
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            if let path {
                Text(path).underline(hovering)
            } else {
                Label {
                    Text("绑定代码目录…").underline(hovering)
                } icon: {
                    Image(systemName: "folder.badge.plus")
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(path == nil ? "选一个目录：在里面运行的 Agent 会出现在这个项目页" : "更换代码目录")
    }
}

private struct EmptyProject: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Text("还没有灵感").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink2)
            Text("在下方记一条，或按 ⌘N 新建").font(.system(size: 13)).foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// 空库首次打开：共享的 EmptyLibrary（同 iOS 的图标与文案），动作是 Mac 的主按钮。
private struct Welcome: View {
    @Environment(\.palette) private var palette
    @State private var creating = false

    var body: some View {
        EmptyLibrary {
            Button { creating = true } label: {
                Text("新建项目").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20).frame(height: 36)
                    .background(palette.accent, in: .capsule)
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 160)
        .sheet(isPresented: $creating) { ProjectForm(project: nil) }
    }
}
#endif
