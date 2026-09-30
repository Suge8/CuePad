#if os(iOS)
import CueStore
import SwiftUI

/// 项目页（nil = 未归档）：目标与下一步 → 工作集（置顶在前）→ 更早。与 Mac 同一套上墙规则。
struct ProjectScreen: View {
    let projectID: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data: ProjectPageData?
    @State private var board = WallBoard()
    @State private var editingProject: Project?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let data, let arrangement = board.arrangement {
                    content(data, arrangement)
                }
            }
            #if DEBUG
            .onChange(of: board.arrangement != nil) { DebugScene.scrollIfNeeded(proxy) }
            #endif
        }
        .background(palette.desk)
        .navigationTitle(data?.project?.name ?? "未归档")
        .navigationSubtitle(data.map { "\($0.cards.count) 张卡片" } ?? "")
        .toolbar { toolbar }
        .sheet(item: $editingProject) { ProjectFormSheet(project: $0) }
        .observing(services.store, [.cards, .projects, .sendRecords, .tasks], id: projectID, into: $data, onError: workspace.fail) {
            [projectID] store in try ProjectPageData.read(projectID, from: store)
        }
        .onChange(of: data?.stamps()) { rearrange() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rearrange() }
        .onChange(of: data?.project?.deletedAt) { _, deleted in if deleted != nil { navigation.pop(projectID) } }
    }

    @ViewBuilder
    private func content(_ data: ProjectPageData, _ arrangement: WallArrangement) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, $0) })
        let lastTarget = data.lastTarget
        VStack(alignment: .leading, spacing: 24) {
            if data.goalCard != nil || !data.tasks.isEmpty { FocusCard(data: data) }
            if data.cards.isEmpty {
                ContentUnavailableView("还没有卡片", systemImage: "square.on.square.dashed", description: Text("在下方随手记里写下想法，或点右上角新建"))
                    .padding(.top, 40)
            }
            if !arrangement.pinned.isEmpty {
                section("置顶", count: arrangement.pinned.count) {
                    wall(arrangement.pinned.compactMap { byID[$0] }, data: data, lastTarget: lastTarget)
                }
            }
            if !arrangement.wall.isEmpty {
                section("工作集", count: arrangement.wall.count) {
                    wall(arrangement.wall.compactMap { byID[$0] }, data: data, lastTarget: lastTarget)
                }
            }
            if !arrangement.older.isEmpty {
                OlderSection(groups: data.olderGroups(arrangement), cards: byID, lastTarget: lastTarget)
                    .id(ScrollAnchor.older)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func section(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
                Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func wall(_ cards: [Card], data: ProjectPageData, lastTarget: [UUID: String]) -> some View {
        MasonryLayout(minColumnWidth: sizeClass == .regular ? 220 : 150, maxColumns: 4, spacing: 12) {
            ForEach(cards) { card in
                CardTileView(card: card, lastTarget: lastTarget[card.id], floated: board.floated.contains(card.id),
                             isGoal: data.project?.goalCardID == card.id)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("新建卡片", systemImage: "square.and.pencil") { newCard() }
                .keyboardShortcut("n")
        }
        if let project = data?.project {
            ToolbarItem(placement: .secondaryAction) {
                ProjectActions(project: project) { editingProject = project }
            }
        }
    }

    private func newCard() {
        let project = projectID
        workspace.attempt {
            let card = try await workspace.createCard(in: project)
            navigation.open(card: card.id)
        }
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

/// 项目的更多操作：置顶、编辑名称与图标、移到回收站。
struct ProjectActions: View {
    let project: Project
    let edit: () -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let id = project.id, pinned = !project.isPinned
        Button(project.isPinned ? "取消置顶" : "置顶", systemImage: project.isPinned ? "pin.slash" : "pin") {
            workspace.perform { try await $0.updateProject(id) { $0.isPinned = pinned } }
        }
        Button("编辑名称与图标", systemImage: "pencil", action: edit)
        Button("移到回收站", systemImage: "trash", role: .destructive) {
            workspace.perform { try await $0.trashProject(id) }
        }
    }
}

/// 目标与下一步：目标卡 + 本项目未完成任务（最多 3 条，其余在任务页）。没有目标卡时只有下一步。
private struct FocusCard: View {
    let data: ProjectPageData
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    private static let visibleTasks = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let goal = data.goalCard {
                let text = CardText(goal.body)
                Button { navigation.open(card: goal.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "目标", systemImage: "scope")
                        Text(text.title).font(.headline).foregroundStyle(palette.ink).multilineTextAlignment(.leading)
                        if !text.preview.isEmpty {
                            Text(VariableText.styled(text.preview, palette)).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if !data.tasks.isEmpty { Divider() }
            }
            if !data.tasks.isEmpty || data.goalCard != nil {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "下一步 · \(data.tasks.count)", systemImage: "checklist")
                    ForEach(data.tasks.prefix(Self.visibleTasks)) { task in TaskLine(task: task) }
                    if data.tasks.count > Self.visibleTasks {
                        Button("还有 \(data.tasks.count - Self.visibleTasks) 条") { navigation.tab = .tasks }
                            .font(.subheadline).foregroundStyle(palette.ink3)
                    }
                    NewTaskLine(project: data.project?.id)
                }
            }
        }
        .padding(16)
        .paper(radius: 18)
    }
}
#endif
