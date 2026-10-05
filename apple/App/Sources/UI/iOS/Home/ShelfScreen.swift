#if os(iOS)
import CueStore
import SwiftUI

/// 书架一次读取的数据。
nonisolated struct ShelfData: Sendable {
    struct Entry: Sendable, Identifiable {
        var project: Project
        var cardCount: Int
        var openTasks: Int
        var goal: String?
        /// 最近修改的一张卡的标题与时间。
        var latest: (title: String, date: Date)?
        /// 该项目最需要注意的 Pi 会话状态；没有会话为 nil。
        var pi: Open<PiWorkState>?
        var id: UUID { project.id }
    }

    var entries: [Entry]
    var inboxCount: Int
    var todayCount: Int
    var trashCount: Int

    static func read(from store: isolated CueStore, now: Date = .now, calendar: Calendar = .current) throws -> ShelfData {
        let summaries = try store.projectSummaries()
        let counts = Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0.cardCount) })
        let openTasks = Dictionary(grouping: try store.tasks(), by: \.projectID).mapValues(\.count)
        let pi = PiSessionState.byProject(try store.piSessionPage(.live).items.map(\.state))
        let entries = try SidebarOrder.projects(store.projects(), summaries: summaries).map { project in
            let latest = try store.search(SearchQuery(projects: [project.id]), limit: 1).cards.first
            return Entry(
                project: project, cardCount: counts[project.id] ?? 0, openTasks: openTasks[project.id] ?? 0,
                goal: try project.goalCardID.flatMap { try store.card($0) }.map { CardText($0.body).title.textGlyphs },
                latest: latest.map { (CardText($0.body).title.textGlyphs, $0.modifiedAt) }, pi: pi[project.id])
        }
        let today = calendar.startOfDay(for: now)...now
        return ShelfData(
            entries: entries, inboxCount: counts[nil] ?? 0,
            todayCount: try store.search(SearchQuery(modifiedIn: today), limit: 0).totalCards,
            trashCount: try store.trashedProjects().count + store.trashedCards().count)
    }
}

/// iPhone 首页：项目书架。顶部一行"今天 · N 张"进入今天流；置顶项目是大卡，其余按最近排成行，都带目标、卡片数、任务数与 Pi 状态点。
struct ShelfScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var data: ShelfData?

    var body: some View {
        ScrollView {
            if let data { content(data) }
        }
        .background(palette.desk)
        .bottomEdgeFade(capturePage: true)
        .captureBar()
        // 一张卡都没有时没什么可搜，不挂搜索框与放大镜
        .cardSearch(.all, available: navigation.layout == .tabs && workspace.catalog?.cardCounts.values.contains { $0 > 0 } == true, ready: true)
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建项目", systemImage: "folder.badge.plus") { navigation.projectForm = .init() }
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink(value: Navigation.Route.settings) { Label("设置", systemImage: "gearshape") }
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink(value: Navigation.Route.trash) {
                    Label(data.map { $0.trashCount > 0 ? "回收站 · \($0.trashCount)" : "回收站" } ?? "回收站", systemImage: "trash")
                }
            }
        }
        .refreshable { await services.syncNow() }
        .observing(services.store, [.projects, .cards, .tasks, .piSessionStates], into: $data, onError: workspace.fail) {
            try ShelfData.read(from: $0)
        }
    }

    @ViewBuilder
    private func content(_ data: ShelfData) -> some View {
        let pinned = data.entries.filter(\.project.isPinned)
        let recent = data.entries.filter { !$0.project.isPinned }
        VStack(alignment: .leading, spacing: 22) {
            if data.todayCount > 0 { TodayLink(count: data.todayCount) }
            if data.entries.isEmpty && data.inboxCount == 0 {
                EmptyShelf { navigation.projectForm = .init() }
            }
            if !pinned.isEmpty {
                // 置顶大卡平分整行：iPhone 至多两列，宽屏至多四列，不留一排窄卡靠左
                let columns = min(pinned.count, sizeClass == .regular ? 4 : 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                    ForEach(pinned) { PinnedShelfCard(entry: $0) }
                }
            }
            if !recent.isEmpty || data.inboxCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "最近")
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, ShelfRow.dividerInset(typeSize)) }
                            ShelfRow(route: .project(entry.project.id), entry: entry)
                        }
                        if data.inboxCount > 0 {
                            if !recent.isEmpty { Divider().padding(.leading, ShelfRow.dividerInset(typeSize)) }
                            ShelfRow(route: .inbox, entry: nil, inboxCount: data.inboxCount)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .paper(radius: 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

/// "今天 · N 张"：进入今天编辑过的卡的时间流。
private struct TodayLink: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationLink(value: Navigation.Route.today) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max").foregroundStyle(palette.ink2).accessibilityHidden(true)
                Text("今天").font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                Text("\(count) 张").font(.body.monospacedDigit()).foregroundStyle(palette.ink3)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)
            .contentShape(.rect)
            .paper(radius: 16)
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel("今天 \(count) 张卡片")
    }
}

/// 置顶项目的大卡：图标、名称、目标、卡片数与未完成任务数、Pi 状态点。
private struct PinnedShelfCard: View {
    let entry: ShelfData.Entry
    @Environment(\.palette) private var palette
    /// 项目图标随字号放大。
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 24

    var body: some View {
        NavigationLink(value: Navigation.Route.project(entry.project.id)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    ProjectGlyph(project: entry.project, size: glyph)
                    Spacer()
                    if let pi = entry.pi { PiStateDot(state: pi, announces: true) }
                }
                Text(entry.project.name).font(.title3.weight(.bold)).foregroundStyle(palette.ink).lineLimit(1)
                Group {
                    if let goal = entry.goal {
                        Text("\(Image(systemName: "scope")) \(goal)").accessibilityLabel(goal)
                    } else {
                        Text("还没有目标")
                    }
                }
                .font(.footnote)
                .foregroundStyle(entry.goal == nil ? palette.ink3 : palette.ink2)
                    .lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                ShelfCounts(cards: entry.cardCount, tasks: entry.openTasks)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .paper(radius: 20)
        }
        .buttonStyle(CardPressStyle())
        .projectActions(entry.project, radius: 20, pi: entry.pi)
        .accessibilityElement(children: .combine)
    }
}

/// 卡片数与未完成任务数。
/// 卡片数与未完成任务数，书架大卡与行里同一种写法："25 张 · 3 项任务"。
private struct ShelfCounts: View {
    let cards: Int
    var tasks = 0
    @Environment(\.palette) private var palette

    var body: some View {
        Text(tasks > 0 ? "\(cards) 张 · \(tasks) 项任务" : "\(cards) 张")
            .font(.caption.monospacedDigit()).foregroundStyle(palette.ink3)
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

/// 书架的一行：项目（副标题是目标，没有目标时是最近一张卡）或未归档。
private struct ShelfRow: View {
    let route: Navigation.Route
    let entry: ShelfData.Entry?
    var inboxCount = 0
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
        ShelfCounts(cards: entry?.cardCount ?? inboxCount, tasks: entry?.openTasks ?? 0)
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                // 辅助功能大字号下图标并进名称一行，文字从行首开始，不空出一列图标宽
                if !stacked {
                    ProjectGlyph(project: entry?.project, size: 17)
                        .frame(width: Self.tile, height: Self.tile)
                        .background(entry.map { Palette.projectTint($0.project.color).opacity(0.12) } ?? palette.fill, in: .rect(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if stacked { ProjectGlyph(project: entry?.project, size: glyph) }
                        Text(entry?.project.name ?? "未归档").font(.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(stacked ? 2 : 1)
                        if let pi = entry?.pi { PiStateDot(state: pi, size: 6, announces: true) }
                    }
                    Group {
                        if entry?.goal?.isEmpty == false {
                            Text("\(Image(systemName: "scope")) \(subtitle)").accessibilityLabel(subtitle)
                        } else {
                            Text(subtitle)
                        }
                    }
                    .font(.footnote).foregroundStyle(palette.ink3).lineLimit(stacked ? 3 : 1)
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
        .projectActions(entry?.project, radius: 16, pi: entry?.pi)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        guard let entry else { return "待整理" }
        if let goal = entry.goal, !goal.isEmpty { return goal }
        if let latest = entry.latest { return "\(latest.title.nonEmpty ?? "空白卡片") · \(DateLabel.short(latest.date))" }
        return "还没有卡片"
    }
}
#endif
