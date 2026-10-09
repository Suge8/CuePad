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

/// 项目页：目标与下一步 → 工作集（置顶在前）→ 更早。与 Mac 同一套上墙规则。
/// 整页是一个懒加载列表：大项目只创建屏幕内的卡与行。
struct ProjectScreen: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: ProjectPage?
    @State private var expanded: Set<OlderGroup.Period> = []
    @State private var board = WallBoard()
    @State private var pi: PiSessionList?
    @State private var agents: AgentLinks?
    @State private var folderGuide: FolderGuide?

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
        // 内容读到后才挂搜索框：推入的页面在内容可滚动时把搜索框收在导航栏下，内容晚到会让已露出的搜索框收起、整页上跳
        .cardSearch(
            project: projectID, available: navigation.layout == .tabs && (workspace.catalog?.cardCounts[projectID] ?? 0) > 0,
            ready: page != nil)
        .floatingHeader(project?.name ?? "", detail: detail.isEmpty ? nil : detail) { actions }
        .environment(\.cardAgents, agents ?? AgentLinks(items: [:], launching: []))
        .observing(services.store, AgentLinks.tables, into: $agents, onError: workspace.fail) { try AgentLinks.read(from: $0) }
        .observingFolderGuide(into: $folderGuide)
        .observing(services.store, [.cards, .projects, .sendRecords], id: projectID, into: $page, onError: workspace.fail) {
            [projectID] store in ProjectPage(try ProjectPageData.read(projectID, from: store))
        }
        .observing(services.store, [.piSessionStates, .deliveryRequests, .projects], id: projectID, into: $pi, onError: workspace.fail) { [projectID] store in
            try PiSessionList.read(text: "", project: projectID, historyLimit: 0, from: store)
        }
        .onChange(of: page?.stamps) { rearrange() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rearrange() }
        .onChange(of: project == nil) { _, gone in if gone { navigation.pop(projectID) } }
    }

    @ViewBuilder
    private func content(_ page: ProjectPage, _ arrangement: WallArrangement) -> some View {
        let data = page.data, lastTarget = data.lastTarget
        // 行距为 0：同一组的"更早"行拼成一张纸（首尾圆角、行间分隔线），段与段之间的距离各自写在段上
        LazyVStack(alignment: .leading, spacing: 0) {
            if data.project != nil { FocusCard(data: data, pi: pi, guide: folderGuide).padding(.bottom, Self.sectionGap) }
            if data.cards.isEmpty {
                // 上面已有任务或会话时页面不是空的：空态缩成一行，不放吉祥物与实心主按钮
                let busy = !data.tasks.roots.isEmpty || pi?.now.isEmpty == false
                EmptyIdeas(compact: busy) { navigation.startCapture(project: .some(projectID)) }.padding(.bottom, busy ? 0 : 24)
            }
            if !arrangement.pinned.isEmpty {
                // 资料：长期参考的灵感，一行一条压在任务区下面
                SectionHeader(title: "资料", count: arrangement.pinned.count).padding(.bottom, Self.headerGap)
                let ids = arrangement.pinned
                VStack(spacing: 0) {
                    ForEach(ids.compactMap { page.entries[$0] }) { entry in
                        OlderRow(entry: entry, lastTarget: lastTarget[entry.id], isFirst: entry.id == ids.first, isLast: entry.id == ids.last)
                    }
                }
                .padding(.bottom, Self.sectionGap)
            }
            if !arrangement.wall.isEmpty {
                SectionHeader(title: "最近", count: arrangement.wall.count).padding(.bottom, Self.headerGap)
                wall(arrangement.wall, page: page, lastTarget: lastTarget).padding(.bottom, Self.sectionGap)
            }
            if !arrangement.older.isEmpty {
                let groups = data.olderGroups(arrangement)
                let titled = OlderGroup.needsTitles(in: groups)
                // 有组标题时由组标题自己与段标题隔开
                SectionHeader(title: "更早", count: arrangement.older.count).id(ScrollAnchor.older).padding(.bottom, titled ? 0 : Self.headerGap)
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

    /// 段与段之间、段标题与它的内容之间的距离（书架、Mac 项目页同一节奏）。
    private static let sectionGap: CGFloat = 24
    private static let headerGap: CGFloat = 8

    /// 名称、目录与计数取自项目目录，推入的第一帧就是最终值：导航栏标题在推入时定下，之后再换会让整页跳一下。
    private var project: Project? { workspace.catalog?.project(projectID) }

    /// 顶栏的一行："25 条灵感 · 2 项任务 · cuepad"（为 0 的不写；绑定的文件夹只写名字，同名的只写一次，`ProjectFolders.names`）。
    /// 全空的项目没有这一行（只写标题）：页面上的空态已经说了"还没有灵感"，一屏不说两遍。
    private var detail: String {
        let catalog = workspace.catalog
        let count = CountCopy.text((catalog?.cardCounts[projectID] ?? 0, "条灵感"), (catalog?.openTasks[projectID] ?? 0, "项任务"))
        return ([count].compactMap { $0 } + ProjectFolders.names(of: projectID, bindings: catalog?.bindings ?? [])).joined(separator: " · ")
    }

    private func wall(_ ids: [UUID], page: ProjectPage, lastTarget: [UUID: String]) -> some View {
        MasonryLayout(minColumnWidth: sizeClass == .regular ? 220 : 150, maxColumns: 4, spacing: 12) {
            ForEach(ids.compactMap { page.entries[$0] }) { entry in
                CardTileView(entry: entry, lastTarget: lastTarget[entry.id], floated: board.floated.contains(entry.id))
                    .transition(Motion.item)
            }
        }
    }

    /// 顶栏右边的"⋯"：新建卡片在前，其后是共用的项目操作。
    private var actions: some View {
        Menu("更多", systemImage: "ellipsis") {
            Button("记一条灵感", systemImage: "square.and.pencil", action: newCard)
            if let project {
                Divider()
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

/// 介绍与任务：项目的一句话介绍在纸外、顶栏下的第一行（次要墨色）；下面总是一张纸：本项目任务（前 3 条没做完的顶层任务连同子任务，
/// 可拖动、缩进，同任务页；没列出的与已完成的只在纸底写个数、点开是任务页，见 `TaskCopy.more`；一条都没有时纸里只有一行"添加任务"）+ 本项目此刻在线的 Agent 会话（这一段只回答"现在谁在干活"，
/// 已结束的不列；有历史时末尾"全部 N 个会话"看这个项目的会话列表；没有在线会话时整段不出现，同 Mac 项目页）。项目还没绑文件夹而有同名建议或正在绑时（`FolderGuide.shows`），Agent 段是绑定引导；
/// 没有建议时不占位置，绑定在项目的"⋯"里。三种项目（多、少、只有任务）是同一个结构，切换项目时眼睛不用重新找。
private struct FocusCard: View {
    let data: ProjectPageData
    let pi: PiSessionList?
    let guide: FolderGuide?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    private static let visibleTasks = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let intro = data.project?.intro {
                Text(intro).font(Typography.secondary).foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .textSelection(.enabled)
            }
            card
        }
    }

    /// 还没绑文件夹、而这里该给绑定引导的项目（同名建议或绑定进行中）。
    private var guided: Project? {
        data.project.flatMap { project in
            !workspace.hasFolder(project.id) && guide?.shows(project.id, in: .inset) == true ? project : nil
        }
    }

    private var card: some View {
        // 两段靠段标题与段间距分组，不画分割线
        VStack(alignment: .leading, spacing: 20) {
            // 与任务页同一节奏：行自带 44pt 命中高度，行间不再加间距
            VStack(alignment: .leading, spacing: 0) {
                let roots = data.tasks.roots
                if !roots.isEmpty {
                    SectionLabel(text: "任务", systemImage: "checklist").padding(.bottom, 4)
                    TaskOutline(tree: data.tasks, roots: Array(roots.prefix(Self.visibleTasks))) { row in
                        TaskLine(task: row.task, marks: data.children[row.id]).contextMenu { CardActions(card: row.task) }
                    }
                }
                if let more = TaskCopy.more(hidden: roots.count - Self.visibleTasks, done: data.taskCounts.done) {
                    Button { navigation.push(.tasks) } label: {
                        HStack(spacing: 4) {
                            Text(more)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                        }
                        .frame(minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .font(Typography.secondary).foregroundStyle(palette.ink3)
                    .accessibilityLabel(more.spoken)
                }
                NewTaskLine(project: data.project?.id)
            }
            if let pi, !pi.now.isEmpty, let project = data.project {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Agent", systemImage: "waveform.path.ecg").padding(.bottom, 6)
                    ForEach(pi.now) { item in sessionLine(item) }
                    if pi.total > 0 {
                        Button { navigation.push(.projectSessions(project.id)) } label: {
                            HStack(spacing: 4) {
                                Text("全部 \(pi.now.count + pi.total) 个会话")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                            }
                            .font(Typography.secondary).foregroundStyle(palette.ink3)
                            .frame(minHeight: 44).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let project = guided {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Agent", systemImage: "waveform.path.ecg").padding(.bottom, 6)
                    ProjectFolderGuide(project: project, guide: guide, style: .inset)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 18)
    }

    private func sessionLine(_ item: PiSessionListItem) -> some View {
        let session = item.state
        // 项目卡里已经是这个项目：不再写所在
        return Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: {
            PiSessionRow(session: session, project: nil, delivery: item.delivery, rename: item.rename)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("看近况、回复")
    }
}
#endif
