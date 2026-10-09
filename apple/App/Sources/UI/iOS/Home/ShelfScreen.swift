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
    /// 各项目的进行中任务，最近开始的在前（`ProjectNow` 的一档）。
    var leading: [UUID: [ProjectNow.InProgress]]
    /// 进任务页的入口上写的数：与任务页分组同一个数（`TaskBoard.counts`）；一条任务都没有时为 nil，没有入口。
    var tasks: TaskCounts?
    /// 正在推进的任务（进行中，最近开始的在前），书架最上面。
    var active: [TaskBoard.Row]
    var inboxCount: Int
    var trashCount: Int

    static let activeLimit = 3

    /// 各项目的"此刻"（`ProjectNow`）：数据变化时算一次，卡与行只拿结果。"正在推进"已列出的任务不再写一遍。
    @MainActor func now(shown: (PiSessionListItem) -> PiShown) -> [UUID: ProjectNow] {
        ProjectNow.byProject(entries.map(\.project), sessions: sessions, tasks: leading, listed: Set(active.map(\.id)), shown: shown)
    }

    static func read(from store: isolated CueStore) throws -> ShelfData {
        let summaries = Dictionary(uniqueKeysWithValues: try store.projectSummaries().map { ($0.projectID, $0) })
        let tasks = try store.taskCounts()
        let entries = try store.projects().map { project in
            Entry(project: project, cardCount: summaries[project.id]?.cardCount ?? 0, openTasks: tasks[project.id]?.open ?? 0)
        }
        let all = tasks.values.reduce(.zero, +)
        return ShelfData(
            entries: entries, sessions: try store.piSessionPage(.current).items, leading: try TaskBoard.leading(from: store),
            tasks: all == .zero ? nil : all,
            active: try TaskBoard.active(limit: activeLimit, from: store),
            inboxCount: summaries[nil]?.cardCount ?? 0,
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
                    // 读到数据时整页淡入，不是一帧里突然铺满
                    if let data { content(data).transition(.opacity) }
                }
                .animation(Motion.quick, value: data == nil)
                .refreshable { await services.syncNow() }
                .hidingSearch($searchHidden, searching: searching)
            }
        }
        // 内容滚到顶上那一排后面时淡出（那一排是下面的 safeAreaBar，整页的遮罩管不到）
        .fadesUnderBars(below: SearchRow.contentGap)
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
        let agent = AgentNow.of(data.sessions, shown: services.settings.shown)
        let wide = sizeClass == .regular && !typeSize.isAccessibilitySize
        LazyVStack(alignment: .leading, spacing: Self.sectionGap) {
            if data.entries.isEmpty && data.inboxCount == 0 {
                VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, agent) }
                EmptyShelf { navigation.projectForm = .init() }
            } else if wide, !pinned.isEmpty, hasLead(data, agent) {
                // 宽屏两栏：左边现在要干的，右边置顶项目；放不下两栏时上下排
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, agent) }.frame(maxWidth: .infinity)
                        // 右栏的大卡按宽度排：窄时一列叠放，宽时两列
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.pinnedMinWidth), spacing: 12)], spacing: 12) {
                            ForEach(pinned) { PinnedShelfCard(entry: $0, now: now[$0.id]) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(minWidth: Self.twoColumnWidth, idealWidth: Self.twoColumnWidth, maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: Self.sectionGap) {
                        VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, agent) }
                        pinnedGrid(pinned, columns: min(pinned.count, 4), now: now)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, agent) }
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
        .padding(.top, SearchRow.contentGap)
        .padding(.bottom, 24)
        // 任务开始、做完时"正在推进"一张张进出，下面的内容跟着挪
        .animation(Motion.snappy, value: data.active.map(\.id))
        .animation(Motion.snappy, value: agent == nil)
        // 宽屏不把一行项目拉满整屏：名字与计数隔太远读不成一行
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private static let readableWidth: CGFloat = 1080
    /// 两级节奏：现在要干的几样（Agent 此刻、正在推进、未分类）之间紧一些，与置顶、最近这些段之间松一些。
    private static let leadGap: CGFloat = 16
    private static let sectionGap: CGFloat = 28
    /// 两栏各至少这么宽才并排（左栏放得下正在推进的一行任务，右栏放得下一张置顶大卡）。
    private static let twoColumnWidth: CGFloat = 640
    private static let pinnedMinWidth: CGFloat = 220

    private func hasLead(_ data: ShelfData, _ agent: AgentNow?) -> Bool {
        agent != nil || !data.active.isEmpty || data.tasks != nil || data.inboxCount > 0
    }

    /// 现在要干的：Agent 此刻、正在推进（没有时是任务入口）、未分类。
    @ViewBuilder
    private func lead(_ data: ShelfData, _ agent: AgentNow?) -> some View {
        let tasksLine = data.active.isEmpty ? data.tasks : nil
        if let agent { AgentNowCard(now: agent).transition(Motion.item) }
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

    /// 置顶大卡按行排：每行 `columns` 张平分整行，最后一行不满时那几张也平分整行，不留空格；最后一行只剩一张时它占满整行、
    /// 横着排成矮的一条（`wide`）——不让单出来的那张（常是最不活跃、甚至空的项目）成为首屏最大的一块。
    /// 一行里的卡同高。置顶的不多，不用懒加载。
    private func pinnedGrid(_ pinned: [ShelfData.Entry], columns: Int, now: [UUID: ProjectNow]) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: pinned.count, by: columns)), id: \.self) { start in
                let row = pinned[start..<min(start + columns, pinned.count)]
                HStack(spacing: 12) {
                    ForEach(row) { PinnedShelfCard(entry: $0, now: now[$0.id], wide: row.count == 1 && columns > 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
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
    let title: String
    let detail: String
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    static let dividerInset: CGFloat = 48

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(palette.ink2).frame(minWidth: 22).accessibilityHidden(true)
                // 辅助字号下说明换到标题下面，不被截成省略号
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 10))) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                    Text(detail).font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
                        .contentTransition(.numericText()).animation(Motion.snappy, value: detail)
                        .spoken(detail)
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

/// 有没归类的灵感时的提醒：点它去未分类整理。图标是墨色——赭黄只给"等你确认"，待整理的灵感不挡任何事。
private struct InboxReminder: View {
    let count: Int

    var body: some View {
        ShelfLine(route: .inbox, symbol: "tray", title: "未分类", detail: "\(count) 条待整理")
    }
}

/// 跨项目的任务："任务 2 进行中 · 3 待办"。
private struct TasksLine: View {
    let tasks: TaskCounts

    var body: some View {
        ShelfLine(route: .tasks, symbol: "checklist", title: "任务", detail: tasks.summary)
    }
}

/// 置顶项目的大卡：项目色从上沿淡下来的一层底、图标、名称、"此刻"一行（`ProjectNow`，没有可说的就不占这一行，名字与计数靠拢）、
/// 灵感数与未完成任务数（都没有时写"还是空的"）。`wide`：一行里单出来的那张占满整行，横着排成矮的一条，图标在左、计数在右。
private struct PinnedShelfCard: View {
    let entry: ShelfData.Entry
    let now: ProjectNow?
    var wide = false
    @Environment(\.palette) private var palette
    /// 项目图标随字号放大。
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 22

    private static let radius: CGFloat = 20

    var body: some View {
        let tint = Palette.projectTint(entry.project.color)
        NavigationLink(value: Navigation.Route.project(entry.project.id)) {
            Group {
                if wide {
                    HStack(spacing: 12) {
                        ProjectGlyph(project: entry.project, size: glyph)
                        VStack(alignment: .leading, spacing: 4) {
                            name
                            if let now { ProjectNowLine(now: now, font: Typography.meta) }
                        }
                        Spacer(minLength: 8)
                        counts
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ProjectGlyph(project: entry.project, size: glyph).padding(.bottom, 6)
                        name
                        if let now { ProjectNowLine(now: now, font: Typography.meta) }
                        Spacer(minLength: 4)
                        counts
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 渐变只铺在填充上（不用渐变描边，见文档「视觉验收 · 性能测量」）
            .background(
                LinearGradient(
                    colors: [tint.opacity(palette.dark ? 0.16 : 0.1), tint.opacity(0)],
                    startPoint: wide ? .leading : .top, endPoint: .center),
                in: .rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
        }
        .buttonStyle(CardPressStyle())
        .projectActions(entry.project, radius: Self.radius, pi: now?.shown)
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(entry.project.name).font(.title3.weight(.bold)).foregroundStyle(palette.ink).lineLimit(1)
    }

    @ViewBuilder private var counts: some View {
        if entry.cardCount == 0, entry.openTasks == 0 {
            Text("还是空的").font(Typography.caption).foregroundStyle(palette.ink3)
        } else {
            ShelfCounts(cards: entry.cardCount, tasks: entry.openTasks)
        }
    }
}

/// 灵感数与未完成任务数，书架大卡与行里同一种写法（`CountCopy`："25 条灵感 · 3 项任务"，为 0 的不写）。
private struct ShelfCounts: View {
    let cards: Int
    var tasks = 0
    @Environment(\.palette) private var palette

    var body: some View {
        if let text = CountCopy.text((cards, "条灵感"), (tasks, "项任务")) {
            Text(text)
                .font(.caption.monospacedDigit()).foregroundStyle(palette.ink3).counting(cards + tasks)
                .lineLimit(1)
                .spoken(text)
        }
    }
}

/// 空库：共用的空库引导，动作是 iOS 的主按钮。
private struct EmptyShelf: View {
    let create: () -> Void

    var body: some View {
        EmptyLibrary {
            EmptyStateButton(title: "新建项目", systemImage: "folder.badge.plus", action: create)
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

    /// 行尾只留灵感数（像侧栏的计数）：把宽度让给"此刻"那一句；任务数在"此刻"与任务页里；为 0 不写。辅助字号下照常写全。
    @ViewBuilder private var counts: some View {
        if stacked {
            ShelfCounts(cards: entry.cardCount, tasks: entry.openTasks)
        } else if entry.cardCount > 0 {
            Text("\(entry.cardCount)").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3).counting(entry.cardCount)
                .accessibilityLabel("\(entry.cardCount) 条灵感")
        }
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
                // 行高一直是两行（名称与"此刻"）的高度，状态出现、消失时列表不跳；没有可说的时名称在行里居中，
                // 不在上半截空出一行（同 Mac 侧栏）
                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: " ").font(.body.weight(.medium))
                        Text(verbatim: " ").font(Typography.meta)
                    }
                    .hidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if stacked { ProjectGlyph(project: entry.project, size: glyph) }
                            Text(entry.project.name).font(.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(stacked ? 2 : 1)
                        }
                        if let now { ProjectNowLine(now: now, font: Typography.meta) }
                        // 辅助功能大字号下计数换到名称下方，名称不被挤成省略号
                        if stacked { counts }
                    }
                    .frame(maxHeight: .infinity, alignment: now == nil ? .center : .top)
                }
                .animation(Motion.quick, value: now == nil)
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
        .accessibilityLabel("全部任务，\(counts.summary.spoken)")
    }
}

/// 正在推进的一行：进行中圆圈（全 App 同一个 `TaskRingView`）、标题，下面是所在项目与会话状态。
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
                TaskRingView(status: .inProgress, ring: .plain, done: false, size: ring)
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
                if row.project != nil, !stacked { Dot().foregroundStyle(palette.ink3) }
                // 辅助字号下计时另起一行，状态词不被截断
                (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 4))) {
                    HStack(spacing: 4) {
                        PiStateDot(shown: shown, size: 6)
                        Text(shown.presence).foregroundStyle(shown.labelTint(palette))
                        if !stacked { Dot().foregroundStyle(palette.ink3) }
                    }
                    PiElapsed(shown: shown, font: .footnote)
                }
                .fixedSize(horizontal: !stacked, vertical: false)
            }
        }
        .font(.footnote).lineLimit(stacked ? 2 : 1)
    }
}

/// 书架顶上的"Agent 此刻"一条（规则 `AgentNow`）：左边是按要紧先后叠放的几个会话头像（首字加状态标，多的写"+N"），
/// 右边一句人话说最要紧的事、次行带过其余的；会话再多也是这两行，高度不变，变的只是字（原地淡入淡出、数字滚动）与头像的进出。
/// 要你动手时整条垫一层那个状态的淡色（等你确认赭黄、出错胭脂），否则中性。点它去 Agent 页；长按快速看前几个、点一个直接进它的对话。
private struct AgentNowCard: View {
    let now: AgentNow
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private static let radius: CGFloat = 20

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                AgentFaces(faces: now.faces, more: now.more, ground: ground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(now.headline).font(Typography.bodyStrong).foregroundStyle(palette.ink).lineLimit(1)
                        .contentTransition(.numericText())
                    // 次行总留着：没有可补的也不让整条变矮
                    Text(now.detail ?? " ").font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(1)
                        .id(now.detail).transition(.opacity)
                }
                .animation(Motion.quick, value: now.headline)
                .animation(Motion.quick, value: now.detail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(now.needsYou ? now.lead.tint(palette).opacity(Self.tint(palette)) : .clear,
                        in: .rect(cornerRadius: Self.radius, style: .continuous))
            .animation(Motion.quick, value: now.needsYou)
            .paper(radius: Self.radius)
            .contentShape(.rect(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .contextMenu {
            ForEach(now.faces) { item in
                let shown = services.settings.shown(item)
                Button { navigation.openSession(item.state.id, sessionID: item.state.sessionID, store: services.store) } label: {
                    Label { Text(item.state.title); Text(shown.label) } icon: { Image(systemName: shown.symbol) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([now.headline, now.detail].compactMap(\.self).joined(separator: "，"))
        .accessibilityHint("去 Agent 页；长按看前几个")
        .accessibilityAddTraits(.isButton)
    }

    private func open() {
        if navigation.layout == .split { navigation.select(.agent) } else { navigation.tab = .agent }
    }

    private static func tint(_ palette: Palette) -> Double { palette.dark ? 0.14 : 0.1 }

    /// 这一条的底色（纸，要你动手时叠一层那个状态的淡色）：头像之间、状态标周围的那圈隔开的描边用它，看起来像镂空。
    private var ground: Color { now.needsYou ? palette.paper.mix(with: now.lead.tint(palette), by: Self.tint(palette)) : palette.paper }
}

/// 叠放的会话头像：认得出是谁——归了项目的是项目图标在项目色的淡底上，没归项目的是文件夹名的首字母在由文件夹名推出的固定颜色上
/// （会话名的首字常是汉字，说明不了是谁）；右下角外沿挂着它的状态标（`PiStateDot`，约头像的四成，"在干活"的转圈与"要重载"分得清；
/// 转圈与呼吸交给 Core Animation，静止时不占 CPU）——同一种状态只挂在最前面那个上：一排一样的标不多说什么，只把视线从主句上拉走。
/// 前一个压着后一个，各带一圈底色描边隔开。多的在后面写"+N"。头像进出是缩放加淡入淡出。
private struct AgentFaces: View {
    let faces: [PiSessionListItem]
    let more: Int
    /// 这一条的底色：隔开头像的描边用它。
    let ground: Color
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 32

    /// 比例都按头像直径算：图标与首字母占 0.44；状态标的点 0.22（符号按它放大到约 0.4），中心落在右下角的外沿上；相邻两个叠 0.16。
    private var badge: CGFloat { size * 0.22 }
    private var overlap: CGFloat { size * 0.16 }

    /// 没归项目的会话按文件夹名取一个固定的颜色：不用黄（近赭黄）与灰（像停用）。
    private static let folderTints = ["#D9774B", "#5E9E5A", "#3F8FB8", "#3AA088", "#A260C4", "#D0607D"]

    var body: some View {
        // 左边的压在右边的上面：最要紧的在最前，它的状态标不被下一个盖住
        let shown = faces.map { services.settings.shown($0) }
        HStack(spacing: -overlap) {
            ForEach(Array(faces.enumerated()), id: \.element.id) { index, item in
                let badged = !shown[..<index].contains { $0.symbol == shown[index].symbol }
                face(item, shown: badged ? shown[index] : nil).zIndex(Double(faces.count - index)).transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if more > 0 {
                // 多出来的个数紧跟在叠放的头像后面，不再垫一个圆：会被前一个头像压住半边
                Text("+\(more)").font(Typography.caption.weight(.semibold).monospacedDigit()).foregroundStyle(palette.ink3)
                    .contentTransition(.numericText())
                    .padding(.leading, overlap + badge)
                    .transition(.opacity)
            }
        }
        .animation(Motion.snappy, value: faces.map(\.id))
        .animation(Motion.snappy, value: more)
        .accessibilityHidden(true)
    }

    private func face(_ item: PiSessionListItem, shown: PiShown?) -> some View {
        let tint = item.project.map { Palette.projectTint($0.color) } ?? Self.tint(folder: item.state.folder ?? item.state.title)
        return mark(item)
            .foregroundStyle(tint)
            .brightness(palette.dark ? 0.12 : 0)
            .frame(width: size, height: size)
            // 实心的底：压在下面的头像不从上面的透出来
            .background(ground.mix(with: tint, by: palette.dark ? 0.3 : 0.16), in: .circle)
            .background(ground, in: .circle.inset(by: -2.5))
            .overlay(alignment: .bottomTrailing) {
                if let shown {
                    PiStateDot(shown: shown, size: badge)
                        .padding(1.5)
                        .background(ground, in: .circle)
                        .offset(x: size * 0.14, y: size * 0.14)
                }
            }
    }

    @ViewBuilder private func mark(_ item: PiSessionListItem) -> some View {
        if let project = item.project {
            Image(systemName: ProjectGlyph.symbol(project.icon)).font(.system(size: size * 0.44, weight: .semibold))
        } else {
            Text((item.state.folder ?? item.state.title).first.map { String($0).uppercased() } ?? "·")
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
        }
    }

    /// 同一个名字总是同一个颜色（不用 `hashValue`：每次启动都变）。
    private static func tint(folder: String) -> Color {
        let sum = folder.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Palette.projectTint(folderTints[sum % folderTints.count])
    }
}
#endif
