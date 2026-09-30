#if os(macOS)
import CueStore
import SwiftUI

/// 项目页：目标与下一步 → 工作集卡片墙（置顶单列在前）→ 更早。
struct ProjectPage: View {
    let projectID: UUID?
    let paperSpace: Namespace.ID
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
            ScrollView {
                if let data, let arrangement = board.arrangement {
                    content(data, arrangement).id("top")
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .overlay { BottomFade() }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > Self.collapseOffset } action: { _, isCollapsed in
                withAnimation(Motion.quick) { collapsed = isCollapsed }
            }
            .overlay(alignment: .top) {
                if collapsed, let data, showsFocus(data) {
                    CompactFocus(data: data) {
                        withAnimation(Motion.spatial(Motion.panel, reduceMotion: reduceMotion)) { proxy.scrollTo("top", anchor: .top) }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            #if DEBUG
            .onChange(of: board.arrangement != nil) { DebugScene.scrollIfNeeded(proxy) }
            #endif
        }
        .observing(services.store, [.cards, .projects, .sendRecords, .tasks, .projectDirectories], id: projectID, into: $data, onError: workspace.fail) { [projectID] store in
            try ProjectPageData.read(projectID, from: store)
        }
        .onChange(of: data?.stamps()) { rearrange() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rearrange() }
    }

    @ViewBuilder
    private func content(_ data: ProjectPageData, _ arrangement: WallArrangement) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0) })
        let lastTarget = data.lastTarget
        VStack(alignment: .leading, spacing: 28) {
            ProjectHeader(data: data)
            if showsFocus(data) { FocusBand(data: data, paperSpace: paperSpace) }
            if data.cards.isEmpty {
                EmptyProject()
            } else {
                if !arrangement.pinned.isEmpty {
                    wallSection(title: "置顶", count: arrangement.pinned.count, ids: arrangement.pinned, byID: byID, data: data, lastTarget: lastTarget)
                }
                if !arrangement.wall.isEmpty {
                    wallSection(title: "最近", count: arrangement.wall.count, ids: arrangement.wall, byID: byID, data: data, lastTarget: lastTarget)
                }
                if !arrangement.older.isEmpty {
                    OlderList(
                        groups: data.olderGroups(arrangement),
                        cards: byID, lastTarget: lastTarget, paperSpace: paperSpace)
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 6).padding(.bottom, 150)
    }

    private func wallSection(title: String, count: Int, ids: [UUID], byID: [UUID: Card], data: ProjectPageData, lastTarget: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink2)
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(palette.ink3)
            }
            MasonryLayout {
                ForEach(ids.compactMap { byID[$0] }) { card in
                    CardTile(
                        card: card, lastTarget: lastTarget[card.id], floated: board.floated.contains(card.id),
                        isGoal: data.project?.goalCardID == card.id, paperSpace: paperSpace)
                }
            }
        }
    }

    /// 有目标卡、未完成任务或本项目的 Pi 会话之一就显示；缺的那一栏各自隐藏。
    private func showsFocus(_ data: ProjectPageData) -> Bool {
        data.goalCard != nil || !data.tasks.isEmpty || !workspace.liveSessions(in: projectID).isEmpty
    }

    private func rearrange() {
        guard let data else { return }
        var next = board
        if next.refresh(with: data, project: projectID) {
            board = next
        } else {
            withAnimation(Motion.spatial(Motion.paper, reduceMotion: reduceMotion)) { board = next }
        }
    }
}

private struct ProjectHeader: View {
    let data: ProjectPageData
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var renaming: Project?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ProjectGlyph(project: data.project, size: 20)
                    Text(data.project?.name ?? "未归档").font(.system(size: 28, weight: .bold)).foregroundStyle(palette.ink)
                }
                .contextMenu { if let project = data.project { ProjectMenu(project: project) { renaming = project } } }
                HStack(spacing: 4) {
                    if let project = data.project {
                        Button(data.directory.map(Self.abbreviated) ?? "绑定代码目录") {
                            ProjectDirectory.choose(for: project.id, workspace: workspace)
                        }
                        .buttonStyle(.plain)
                        .help(data.directory == nil ? "在这个目录里运行的 Pi 会出现在项目页" : "更换代码目录")
                        Text("·")
                    }
                    Text("\(data.cards.count) 张卡片").monospacedDigit()
                }
                .font(.system(size: 12)).foregroundStyle(palette.ink3)
            }
            Spacer()
            NewCardButton(project: data.project?.id)
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
        Button("新建卡片", systemImage: "plus") {
            let project = project
            workspace.attempt { workspace.openCard = try await workspace.createCard(in: project).id }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .help("新建卡片（⌘N）")
    }
}

private struct EmptyProject: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed").font(.system(size: 28)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            Text("这个项目还没有卡片").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink2)
            Text("在下方输入框记下想法按 ↩ 存为卡片，或按 ⌘N 新建").font(.system(size: 13)).foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
#endif
