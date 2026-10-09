#if os(iOS)
import CueStore
import SwiftUI

/// 书架一次读取的数据。
nonisolated struct ShelfData: Sendable {
    struct Entry: Sendable, Identifiable {
        var project: Project
        var cardCount: Int
        var openTasks: Int
        var id: UUID { project.id }
    }

    var entries: [Entry]
    /// 此刻有事的 Pi 会话（在线的，加上还有话发给它的已结束会话；带发给它的最近一条投送请求，`PiSessionQuery.current`）：
    /// 各项目的"此刻"一行在界面上再按本机的规则挑（`ProjectNow`）。
    var sessions: [PiSessionListItem]
    /// 各项目最近开始的进行中任务标题（`ProjectNow` 的一档）。
    var leading: [UUID: String]
    /// 等你确认的在线会话（书架最上面的"等你"）；个数与 Agent 角标同一个数。
    var waiting: [PiSessionListItem] { sessions.filter(\.state.waitsForYou) }
    /// 进任务页的入口上写的数：与任务页分组同一个数（`TaskBoard.counts`）；一条任务都没有时为 nil，没有入口。
    var tasks: TaskCounts?
    /// 正在推进的任务（进行中，最近开始的在前），书架最上面。
    var active: [TaskBoard.Row]
    var inboxCount: Int
    var trashCount: Int

    static let activeLimit = 3

    /// 各项目的"此刻"（`ProjectNow`）：数据变化时算一次，卡与行只拿结果。
    @MainActor func now(shown: (PiSessionListItem) -> PiShown) -> [UUID: ProjectNow] {
        ProjectNow.byProject(entries.map(\.project), sessions: sessions, tasks: leading, shown: shown)
    }

    static func read(from store: isolated CueStore) throws -> ShelfData {
        let summaries = try store.projectSummaries()
        let counts = Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0.cardCount) })
        let tasks = try store.taskCounts()
        let entries = try store.projects().map { project in
            Entry(project: project, cardCount: counts[project.id] ?? 0, openTasks: tasks[project.id]?.open ?? 0)
        }
        let hasTasks = tasks.values.contains { $0.total > 0 }
        return ShelfData(
            entries: entries, sessions: try store.piSessionPage(.current).items, leading: try TaskBoard.leading(from: store),
            tasks: hasTasks ? try TaskBoard.counts(from: store) : nil,
            active: try TaskBoard.active(limit: activeLimit, from: store),
            inboxCount: counts[nil] ?? 0,
            trashCount: try store.trashedProjects().count + store.trashedCards().count)
    }
}

/// iPhone 首页：项目书架。顶上一排：左"⋯"（未分类、回收站、设置），中间搜索灵感与任务（输入时页面换成搜索结果，往下滑时藏起），右"新建项目"；
/// iPad 分栏里这些都在侧栏，顶上不放。从上往下回答"现在该干什么"：有 Agent 等你确认时最上面一张"等你"（点它去 Agent）；
/// 然后是一屏的重点"正在推进"：进行中的任务排在一张纸上（点开是任务浮窗），标题右边是全部任务的计数、点它进任务页；
/// 没有进行中的任务时，只剩一行"任务 · N 待办"做入口。有没归类的灵感时一行提醒去整理；置顶项目是大卡，其余按最近排成行。
/// 宽屏（iPad）放得下时，上面这几样与置顶项目并排两栏。
struct ShelfScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var data: ShelfData?
    @State private var query = PaletteQuery()
    @FocusState private var searchFocused: Bool
    @State private var searchHidden = false
    @Environment(\.tabPageReady) private var tabPageReady

    /// 一张卡都没有时没什么可搜，不放搜索框。
    private var searchable: Bool { workspace.catalog?.cardCounts.values.contains { $0 > 0 } == true }
    private var searching: Bool { searchFocused || !query.text.isEmpty }

    var body: some View {
        Group {
            if searching {
                CardSearchResults(query: $query, scope: .all)
            } else {
                ScrollView {
                    if let data { content(data) }
                }
                .refreshable { await services.syncNow() }
                .hidingSearch($searchHidden, searching: searching)
            }
        }
        // 不显示标题：顶上只有那一排，内容多露出来；标题仍是读屏与多任务切换器里的名字
        .navigationTitle("灵感")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .safeAreaBar(edge: .top) {
            if navigation.layout == .tabs { row }
        }
        .toolbarVisibility(navigation.layout == .tabs ? .hidden : .automatic, for: .navigationBar)
        .onAppear(perform: focusIfRequested)
        .onChange(of: navigation.pendingPageSearch) { focusIfRequested() }
        #if DEBUG
        .onAppear {
            guard DebugScene.activatesSearch(.all) else { return }
            query.text = DebugScene.searchText
            searchFocused = true
        }
        #endif
        .onChange(of: data != nil, initial: true) { _, loaded in if loaded { tabPageReady() } }
        .observing(services.store, [.projects, .cards, .piSessionStates, .deliveryRequests], into: $data, onError: workspace.fail) {
            try ShelfData.read(from: $0)
        }
    }

    @ViewBuilder
    private func content(_ data: ShelfData) -> some View {
        let pinned = data.entries.filter(\.project.isPinned)
        let recent = data.entries.filter { !$0.project.isPinned }
        // 各项目的"此刻"在数据变化时算一次，卡与行只拿结果
        let now = data.now(shown: services.settings.shown)
        let wide = sizeClass == .regular && !typeSize.isAccessibilitySize
        LazyVStack(alignment: .leading, spacing: 22) {
            if data.entries.isEmpty && data.inboxCount == 0 {
                lead(data)
                EmptyShelf { navigation.projectForm = .init() }
            } else if wide, !pinned.isEmpty, hasLead(data) {
                // 宽屏两栏：左边现在要干的，右边置顶项目；放不下两栏时上下排
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 22) { lead(data) }.frame(maxWidth: .infinity)
                        // 右栏的大卡按宽度排：窄时一列叠放，宽时两列
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.pinnedMinWidth), spacing: 12)], spacing: 12) {
                            ForEach(pinned) { PinnedShelfCard(entry: $0, now: now[$0.id]) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(minWidth: Self.twoColumnWidth, idealWidth: Self.twoColumnWidth, maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 22) {
                        lead(data)
                        pinnedGrid(pinned, columns: min(pinned.count, 4), now: now)
                    }
                }
            } else {
                lead(data)
                if !pinned.isEmpty {
                    // 置顶大卡平分整行：iPhone 至多两列，宽屏至多四列，不留一排窄卡靠左
                    pinnedGrid(pinned, columns: typeSize.isAccessibilitySize ? 1 : min(pinned.count, wide ? 4 : 2), now: now)
                }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "最近")
                    LazyVStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, ShelfRow.dividerInset(typeSize)) }
                            ShelfRow(entry: entry, now: now[entry.id])
                        }
                    }
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .paper(radius: 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        // 任务开始、做完时"正在推进"一张张进出，下面的内容跟着挪
        .animation(Motion.snappy, value: data.active.map(\.id))
        .animation(Motion.snappy, value: data.waiting.map(\.id))
        // 宽屏不把一行项目拉满整屏：名字与计数隔太远读不成一行
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private static let readableWidth: CGFloat = 1080
    /// 两栏各至少这么宽才并排（左栏放得下正在推进的一行任务，右栏放得下一张置顶大卡）。
    private static let twoColumnWidth: CGFloat = 640
    private static let pinnedMinWidth: CGFloat = 220

    private func hasLead(_ data: ShelfData) -> Bool {
        !data.waiting.isEmpty || !data.active.isEmpty || data.tasks != nil || data.inboxCount > 0
    }

    /// 现在要干的：等你、正在推进（没有时是任务入口）、未分类。
    @ViewBuilder
    private func lead(_ data: ShelfData) -> some View {
        let tasksLine = data.active.isEmpty ? data.tasks : nil
        if !data.waiting.isEmpty { WaitingCard(items: data.waiting).transition(Motion.item) }
        if !data.active.isEmpty { ActiveTasks(rows: data.active, counts: data.tasks).transition(Motion.item) }
        if data.inboxCount > 0 || tasksLine != nil {
            VStack(spacing: 0) {
                if let tasksLine { TasksLine(tasks: tasksLine) }
                if data.inboxCount > 0, tasksLine != nil { Divider().padding(.leading, ShelfLine.dividerInset) }
                if data.inboxCount > 0 { InboxReminder(count: data.inboxCount) }
            }
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .paper(radius: 16)
        }
    }

    private func pinnedGrid(_ pinned: [ShelfData.Entry], columns: Int, now: [UUID: ProjectNow]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            ForEach(pinned) { PinnedShelfCard(entry: $0, now: now[$0.id]) }
        }
    }

    /// 左"⋯"（未分类、回收站、设置），中间搜索（什么都没有时没什么可搜，不放），右"新建项目"。
    private var row: some View {
        SearchRow(
            search: searchable ? SearchCapsule(prompt: "搜索灵感与任务", query: $query.text, focus: $searchFocused) : nil,
            searchHidden: searchHidden
        ) {
            menu
        } trailing: {
            Button("新建项目", systemImage: "folder.badge.plus") { navigation.projectForm = .init() }
        }
    }

    private var menu: some View {
        Menu {
            Button(count("未分类", data?.inboxCount), systemImage: "tray") { navigation.push(.inbox) }
            Button("归档", systemImage: "archivebox") { navigation.push(.archive) }
            Button(count("回收站", data?.trashCount), systemImage: "trash") { navigation.push(.trash) }
            Button("设置", systemImage: "gearshape") { navigation.push(.settings) }
        } label: {
            Label("更多", systemImage: "ellipsis")
        }
    }

    private func count(_ title: String, _ n: Int?) -> String {
        guard let n, n > 0 else { return title }
        return "\(title) · \(n)"
    }

    /// ⌘K 指名书架时聚焦搜索框（标签栏布局，见 `Navigation.searchCurrentPage`）。
    private func focusIfRequested() {
        guard navigation.pendingPageSearch == .shelf else { return }
        navigation.pendingPageSearch = nil
        searchFocused = true
    }
}

/// 书架顶上的一行：图标、标题、说明，点进一页。
private struct ShelfLine: View {
    let route: Navigation.Route
    let symbol: String
    var tint: Color?
    let title: String
    let detail: String
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    static let dividerInset: CGFloat = 48

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint ?? palette.ink2).frame(minWidth: 22).accessibilityHidden(true)
                // 辅助字号下说明换到标题下面，不被截成省略号
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 10))) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                    Text(detail).font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
                        .contentTransition(.numericText()).animation(Motion.snappy, value: detail)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .background(palette.paper)
        .accessibilityElement(children: .combine)
    }
}

/// 有没归类的灵感时的提醒（注意色的图标）：点它去未分类整理。
private struct InboxReminder: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        ShelfLine(route: .inbox, symbol: "tray", tint: palette.attention, title: "未分类", detail: "\(count) 条待整理")
    }
}

/// 跨项目的任务："任务 2 进行中 · 3 待办"。
private struct TasksLine: View {
    let tasks: TaskCounts

    var body: some View {
        ShelfLine(route: .tasks, symbol: "checklist", title: "任务", detail: tasks.summary)
    }
}

/// 置顶项目的大卡：项目色从上沿淡下来的一层底、图标、名称、"此刻"一行（`ProjectNow`）、灵感数与未完成任务数。
private struct PinnedShelfCard: View {
    let entry: ShelfData.Entry
    let now: ProjectNow?
    @Environment(\.palette) private var palette
    /// 项目图标随字号放大。
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 22

    private static let radius: CGFloat = 20

    var body: some View {
        let tint = Palette.projectTint(entry.project.color)
        NavigationLink(value: Navigation.Route.project(entry.project.id)) {
            VStack(alignment: .leading, spacing: 6) {
                ProjectGlyph(project: entry.project, size: glyph).padding(.bottom, 6)
                Text(entry.project.name).font(.title3.weight(.bold)).foregroundStyle(palette.ink).lineLimit(1)
                ProjectNowLine(now: now, font: .footnote)
                Spacer(minLength: 10)
                ShelfCounts(cards: entry.cardCount, tasks: entry.openTasks)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            // 渐变只铺在填充上（不用渐变描边，见文档「视觉验收 · 性能测量」）
            .background(
                LinearGradient(colors: [tint.opacity(palette.dark ? 0.16 : 0.1), tint.opacity(0)], startPoint: .top, endPoint: .center),
                in: .rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
        }
        .buttonStyle(CardPressStyle())
        .projectActions(entry.project, radius: Self.radius, pi: now?.shown)
        .accessibilityElement(children: .combine)
    }
}

/// 灵感数与未完成任务数，书架大卡与行里同一种写法："25 张 · 3 项任务"。
private struct ShelfCounts: View {
    let cards: Int
    var tasks = 0
    @Environment(\.palette) private var palette

    var body: some View {
        Text(tasks > 0 ? "\(cards) 条灵感 · \(tasks) 项任务" : "\(cards) 条灵感")
            .font(.caption.monospacedDigit()).foregroundStyle(palette.ink3).counting(cards + tasks)
            .lineLimit(1)
    }
}

/// 空库：共用的空库引导，动作是 iOS 的主按钮。
private struct EmptyShelf: View {
    let create: () -> Void

    var body: some View {
        EmptyLibrary {
            Button("新建项目", action: create).prominentButton().controlSize(.large).frame(minHeight: 44)
        }
        .padding(.top, 80)
    }
}

/// 书架的一行：项目名，下面是"此刻"一行（`ProjectNow`）。
private struct ShelfRow: View {
    let entry: ShelfData.Entry
    let now: ProjectNow?
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 辅助字号下并进名称一行的图标随字号放大；平时在固定大小的图标块里。
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17

    private var stacked: Bool { typeSize.isAccessibilitySize }

    static let tile: CGFloat = 36
    static let horizontalPadding: CGFloat = 14
    /// 行间分隔线的起点：与名称左缘对齐。
    static func dividerInset(_ typeSize: DynamicTypeSize) -> CGFloat {
        typeSize.isAccessibilitySize ? horizontalPadding : horizontalPadding + tile + 12
    }

    private var counts: some View {
        ShelfCounts(cards: entry.cardCount, tasks: entry.openTasks)
    }

    var body: some View {
        NavigationLink(value: Navigation.Route.project(entry.project.id)) {
            HStack(spacing: 12) {
                // 辅助功能大字号下图标并进名称一行，文字从行首开始，不空出一列图标宽
                if !stacked {
                    ProjectGlyph(project: entry.project, size: 17)
                        .frame(width: Self.tile, height: Self.tile)
                        .background(Palette.projectTint(entry.project.color).opacity(0.12), in: .rect(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if stacked { ProjectGlyph(project: entry.project, size: glyph) }
                        Text(entry.project.name).font(.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(stacked ? 2 : 1)
                    }
                    ProjectNowLine(now: now, font: .footnote)
                    // 辅助功能大字号下计数换到名称下方，名称不被挤成省略号
                    if stacked { counts }
                }
                Spacer(minLength: 8)
                if !stacked { counts }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Self.horizontalPadding).padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .background(palette.paper)
        .projectActions(entry.project, radius: 16, pi: now?.shown)
        .accessibilityElement(children: .combine)
    }
}

/// 正在推进：一屏的重点。进行中的任务排在一张纸上，每行是标题、所在项目、交给 Agent 的会话此刻在做什么，点开是任务浮窗；
/// 标题右边是全部任务的计数，点它进任务页——单独一行"任务 · N 进行中"会与下面这几行重复报进行中，所以并进标题。
private struct ActiveTasks: View {
    let rows: [TaskBoard.Row]
    let counts: TaskCounts?
    @Environment(\.palette) private var palette

    static let radius: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 放不下一行（辅助功能大字号）时计数换到标题下面，不把标题挤成两行
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 8)
                    if let counts { allTasks(counts) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    title
                    if let counts { allTasks(counts) }
                }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    ActiveTaskRow(row: row, divided: row.id != rows.first?.id).transition(Motion.item)
                }
            }
            .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
        }
    }

    private var title: some View {
        Text("正在推进").font(.title3.weight(.bold)).foregroundStyle(palette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func allTasks(_ counts: TaskCounts) -> some View {
        NavigationLink(value: Navigation.Route.tasks) {
            HStack(spacing: 3) {
                Text(counts.summary).contentTransition(.numericText()).animation(Motion.snappy, value: counts.summary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink2)
            .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("全部任务，\(counts.summary)")
    }
}

/// 正在推进的一行：进行中圆圈（颜色同 `TaskGlyph`）、标题，下面是所在项目与会话状态。
private struct ActiveTaskRow: View {
    let row: TaskBoard.Row
    let divided: Bool
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var scaledRing: CGFloat = 20

    /// 圆圈随字号放大，到辅助字号封顶：再大只会把标题往右挤。
    private var ring: CGFloat { min(scaledRing, 28) }
    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        Button { navigation.openTask(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: TaskGlyph.symbol(.inProgress)).font(.system(size: ring))
                    .foregroundStyle(TaskGlyph.tint(.inProgress, palette)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.task.title.textGlyphs).font(.headline).foregroundStyle(palette.ink)
                        .lineLimit(stacked ? 4 : 2).multilineTextAlignment(.leading)
                    meta
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .background(palette.paper)
        .overlay(alignment: .top) {
            if divided { palette.hair.frame(height: 1).padding(.leading, 16 + ring + 12) }
        }
        .contextMenu { CardActions(card: row.task) }
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开任务")
    }

    /// 项目与会话状态平时排成一行；辅助字号下上下排、可换行，不撑出纸外。
    private var meta: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            if let project = row.project {
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 11)
                    Text(project.name)
                }
                .foregroundStyle(palette.ink3)
                .layoutPriority(-1)
            }
            if let session = row.session {
                let shown = services.settings.shown(session, delivery: row.delivery)
                if row.project != nil, !stacked { Text("·").foregroundStyle(palette.ink3).accessibilityHidden(true) }
                // 辅助字号下计时另起一行，状态词不被截断
                (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 4))) {
                    HStack(spacing: 4) {
                        PiStateDot(shown: shown, size: 6)
                        Text(shown.presence).foregroundStyle(shown.labelTint(palette))
                        if !stacked { Text("·").foregroundStyle(palette.ink3) }
                    }
                    PiElapsed(shown: shown, font: .footnote)
                }
                .fixedSize(horizontal: !stacked, vertical: false)
            }
        }
        .font(.footnote).lineLimit(stacked ? 2 : 1)
    }
}

/// 等你：有 Agent 等你确认时书架最上面的一张——几个在等；点它去 Agent 页回答。归在项目里的会话问了什么已写在那个项目的
/// "此刻"一行，这里不再重复；只有不在项目里的（没有别处写它）才在这里写出它的问题。赭黄只落在图标与一层淡底上，问题正文是墨色。
private struct WaitingCard: View {
    let items: [PiSessionListItem]
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    private static let radius: CGFloat = 20

    var body: some View {
        let first = items[0].state
        let loose = items.first { $0.state.projectID == nil }?.state
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "questionmark.circle.fill").font(.title3).foregroundStyle(palette.attention)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(items.count == 1 ? "\(first.title) 在等你确认" : "\(items.count) 个 Agent 在等你确认")
                        .font(.headline).foregroundStyle(palette.ink)
                        .contentTransition(.numericText()).animation(Motion.snappy, value: items.count)
                    if let loose, let ask = PiProgress.line(of: loose) {
                        Text(items.count == 1 ? ask : "\(loose.title)：\(ask)")
                            .font(.subheadline).foregroundStyle(palette.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.attention.opacity(palette.dark ? 0.14 : 0.1), in: .rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
            .contentShape(.rect(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("去 Agent 页回答")
    }

    private func open() {
        if navigation.layout == .split { navigation.select(.agent) } else { navigation.tab = .agent }
    }
}
#endif
