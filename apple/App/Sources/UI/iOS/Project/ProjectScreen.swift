#if os(iOS)
import CueStore
import SwiftUI

/// 项目页的数据：读取时一并算好上墙用的卡片事实与每张卡的摘要（在 Store 的执行体上，不占主线程）。
nonisolated private struct ProjectPage: Sendable {
    var data: ProjectPageData
    var stamps: [CardStamp]
    var entries: [UUID: CardEntry]

    init(_ data: ProjectPageData) {
        self.data = data
        stamps = data.stamps()
        entries = Dictionary(uniqueKeysWithValues: data.cards.map { ($0.id, CardEntry($0)) })
    }
}

/// 项目页（nil = 未归档）：目标与下一步 → 工作集（置顶在前）→ 更早。与 Mac 同一套上墙规则。
/// 整页是一个懒加载列表：大项目只创建屏幕内的卡与行。
struct ProjectScreen: View {
    let projectID: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: ProjectPage?
    @State private var expanded: Set<OlderGroup.Period> = []
    @State private var board = WallBoard()
    @State private var sessions: [PiSessionState]?

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                if let page, let arrangement = board.arrangement {
                    content(page, arrangement)
                }
                #if DEBUG
                Color.clear.frame(height: 0)
                    .onChange(of: board.arrangement != nil) { DebugScene.scrollIfNeeded(proxy) }
                #endif
            }
        }
        .background(palette.desk)
        .bottomEdgeFade(capturePage: true)
        .captureBar()
        .cardSearch(.project(projectID), enabled: navigation.layout == .tabs)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .observing(services.store, [.cards, .projects, .sendRecords, .tasks], id: projectID, into: $page, onError: workspace.fail) {
            [projectID] store in ProjectPage(try ProjectPageData.read(projectID, from: store))
        }
        .observing(services.store, [.piSessionStates], id: projectID, into: $sessions) { [projectID] store in
            try store.piSessionStates().filter { $0.projectID != nil && $0.projectID == projectID }
        }
        .onChange(of: page?.stamps) { rearrange() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rearrange() }
        .onChange(of: project == nil) { _, gone in if gone, projectID != nil { navigation.pop(projectID) } }
    }

    @ViewBuilder
    private func content(_ page: ProjectPage, _ arrangement: WallArrangement) -> some View {
        let data = page.data, lastTarget = data.lastTarget
        LazyVStack(alignment: .leading, spacing: 12) {
            if data.project != nil { FocusCard(data: data, sessions: sessions ?? []).padding(.bottom, 12) }
            if data.cards.isEmpty {
                ContentUnavailableView {
                    Label("还没有卡片", systemImage: "square.on.square.dashed")
                } description: {
                    Text("写一张，或者在下方随手记一条")
                } actions: {
                    Button("新建卡片", action: newCard).prominentButton().controlSize(.large)
                }
                .padding(.top, 24)
            }
            if !arrangement.pinned.isEmpty {
                SectionHeader(title: "置顶", count: arrangement.pinned.count)
                wall(arrangement.pinned, page: page, lastTarget: lastTarget).padding(.bottom, 12)
            }
            if !arrangement.wall.isEmpty {
                SectionHeader(title: "最近", count: arrangement.wall.count)
                wall(arrangement.wall, page: page, lastTarget: lastTarget).padding(.bottom, 12)
            }
            if !arrangement.older.isEmpty {
                SectionHeader(title: "更早", count: arrangement.older.count).id(ScrollAnchor.older)
                let groups = data.olderGroups(arrangement)
                let titled = OlderGroup.needsTitles(in: groups)
                ForEach(groups, id: \.period) { group in
                    if titled { OlderGroupHeader(group: group, expanded: $expanded) }
                    if !group.isMonth || expanded.contains(group.period) {
                        let ids = group.cards
                        ForEach(ids, id: \.self) { id in
                            if let entry = page.entries[id] {
                                OlderRow(entry: entry, lastTarget: lastTarget[id], isFirst: id == ids.first, isLast: id == ids.last)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    /// 名称、目录与计数取自项目目录，推入的第一帧就是最终值：导航栏标题在推入时定下，之后再换会让整页跳一下。
    private var project: Project? { workspace.catalog?.project(projectID) }

    private var title: String {
        projectID == nil ? "未归档" : project?.name ?? ""
    }

    private var subtitle: String {
        let catalog = workspace.catalog
        let directory = projectID.flatMap { catalog?.directories[$0] }.map(Self.homeRelative)
        let count = catalog?.cardCounts[projectID].flatMap { $0 > 0 ? "\($0) 张卡片" : nil }
        return [directory, count].compactMap { $0 }.joined(separator: " · ")
    }

    /// 绑定的目录是 Mac 上的路径：`/Users/<name>/…` 显示成 `~/…`。
    private static func homeRelative(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 3, parts[1] == "Users" else { return path }
        return "~/" + parts.dropFirst(3).joined(separator: "/")
    }

    private func wall(_ ids: [UUID], page: ProjectPage, lastTarget: [UUID: String]) -> some View {
        MasonryLayout(minColumnWidth: sizeClass == .regular ? 220 : 150, maxColumns: 4, spacing: 12) {
            ForEach(ids.compactMap { page.entries[$0] }) { entry in
                CardTileView(entry: entry, lastTarget: lastTarget[entry.id], floated: board.floated.contains(entry.id),
                             isGoal: page.data.project?.goalCardID == entry.id)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("新建卡片", systemImage: "square.and.pencil") { newCard() }
        }
        if let project {
            ToolbarItem(placement: .secondaryAction) {
                ProjectActions(project: project) { navigation.projectForm = .init(project: project) }
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
        guard let data = page?.data else { return }
        var next = board
        if next.refresh(with: data, project: projectID) {
            board = next
        } else {
            withAnimation(Motion.spatial(Motion.paper, reduceMotion: reduceMotion)) { board = next }
        }
    }
}

/// 目标与下一步：目标卡 + 本项目未完成任务（最多 3 条，其余在任务页）+ 本项目的 Pi 会话。
/// 没有目标卡时只有下一步；什么都没有时是一行"添加任务"。
private struct FocusCard: View {
    let data: ProjectPageData
    let sessions: [PiSessionState]
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    private static let visibleTasks = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let goal = data.goalCard {
                let text = CardEntry(goal).text
                Button { navigation.open(card: goal.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "目标", systemImage: "scope")
                        Text(text.title.nonEmpty ?? "空白卡片").font(.headline).foregroundStyle(palette.ink).multilineTextAlignment(.leading)
                        if !text.preview.isEmpty {
                            Text(VariableText.styled(text.preview, palette)).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: data.tasks.isEmpty ? "下一步" : "下一步 · \(data.tasks.count)", systemImage: "checklist")
                ForEach(data.tasks.prefix(Self.visibleTasks)) { task in TaskLine(task: task) }
                if data.tasks.count > Self.visibleTasks {
                    Button("还有 \(data.tasks.count - Self.visibleTasks) 条") {
                        if navigation.layout == .split { navigation.panel = .tasks } else { navigation.tab = .tasks }
                    }
                    .font(.subheadline).foregroundStyle(palette.ink3)
                    .frame(minHeight: 44)
                }
                NewTaskLine(project: data.project?.id)
            }
            .animation(.easeOut(duration: 0.2), value: data.tasks.map(\.id))
            if !sessions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Pi", systemImage: "terminal")
                    ForEach(sessions) { session in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            PiDot(state: session.state, size: 7)
                            Text(session.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink)
                            PiActivityLine(lead: [session.state.label], detail: session.detail, detailIsCode: session.detailIsCode, font: .subheadline)
                                .foregroundStyle(palette.ink2)
                            Spacer(minLength: 4)
                            PiElapsed(session: session)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(16)
        .paper(radius: 18)
    }
}
#endif
