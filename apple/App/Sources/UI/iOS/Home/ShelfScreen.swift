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
        var id: UUID { project.id }
    }

    /// 跨项目的未完成任务数（书架的"任务"一行）；一条任务都没有时为 nil，不显示这一行。
    struct TaskCounts: Sendable, Equatable {
        var inProgress: Int
        var todo: Int
    }

    var entries: [Entry]
    /// 在线的 Pi 会话（带发给它的最近一条投送请求）：项目的状态点在界面上再按本机的规则算（`PiSessionListItem.byProject`）。
    var live: [PiSessionListItem]
    var tasks: TaskCounts?
    var inboxCount: Int
    var trashCount: Int

    static func read(from store: isolated CueStore) throws -> ShelfData {
        let summaries = try store.projectSummaries()
        let counts = Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0.cardCount) })
        let progress = try store.taskProgress()
        let entries = try store.projects().map { project in
            let latest = try store.search(SearchQuery(projects: [project.id]), limit: 1).cards.first
            return Entry(
                project: project, cardCount: counts[project.id] ?? 0, openTasks: progress[project.id].map { $0.total - $0.done } ?? 0,
                goal: try project.goalCardID.flatMap { try store.card($0) }.map { CardText($0.body).title.textGlyphs },
                latest: latest.map { (CardText($0.body).title.textGlyphs, $0.modifiedAt) })
        }
        let hasTasks = progress.values.contains { $0.total > 0 }
        return ShelfData(
            entries: entries, live: try store.piSessionPage(.live).items,
            tasks: hasTasks
                ? TaskCounts(inProgress: try store.tasks(.inProgress).flatMap(\.tasks).count, todo: try store.tasks(.todo).flatMap(\.tasks).count)
                : nil,
            inboxCount: counts[nil] ?? 0,
            trashCount: try store.trashedProjects().count + store.trashedCards().count)
    }
}

/// iPhone 首页：项目书架。最上面一张纸：有没归类的想法时一行提醒去整理，有任务时一行"任务 · N 进行中 · N 待办"进入跨项目任务页；
/// 置顶项目是大卡，其余按最近排成行，都带目标、卡片数、任务数与 Pi 状态点。
struct ShelfScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var data: ShelfData?

    var body: some View {
        ScrollView {
            if let data { content(data) }
        }
        .captureBar()
        // 一张卡都没有时没什么可搜，不挂搜索框与放大镜
        .cardSearch(.all, available: navigation.layout == .tabs && workspace.catalog?.cardCounts.values.contains { $0 > 0 } == true, ready: true)
        // 不显示大标题：顶上只留浮着的玻璃按钮与搜索，内容多露出来；标题仍是读屏与多任务切换器里的名字
        .navigationTitle("项目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
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
        .observing(services.store, [.projects, .cards, .tasks, .piSessionStates, .deliveryRequests], into: $data, onError: workspace.fail) {
            try ShelfData.read(from: $0)
        }
    }

    @ViewBuilder
    private func content(_ data: ShelfData) -> some View {
        let pinned = data.entries.filter(\.project.isPinned)
        let recent = data.entries.filter { !$0.project.isPinned }
        let pi = PiSessionListItem.byProject(data.live, shown: services.settings.shown)
        VStack(alignment: .leading, spacing: 22) {
            if data.inboxCount > 0 || data.tasks != nil {
                VStack(spacing: 0) {
                    if data.inboxCount > 0 { InboxReminder(count: data.inboxCount) }
                    if data.inboxCount > 0, data.tasks != nil { Divider().padding(.leading, ShelfLine.dividerInset) }
                    if let tasks = data.tasks { TasksLine(tasks: tasks) }
                }
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .paper(radius: 16)
            }
            if data.entries.isEmpty && data.inboxCount == 0 {
                EmptyShelf { navigation.projectForm = .init() }
            }
            if !pinned.isEmpty {
                // 置顶大卡平分整行：iPhone 至多两列，宽屏至多四列，不留一排窄卡靠左
                let columns = min(pinned.count, sizeClass == .regular ? 4 : 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                    ForEach(pinned) { PinnedShelfCard(entry: $0, pi: pi[$0.id]) }
                }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "最近")
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, ShelfRow.dividerInset(typeSize)) }
                            ShelfRow(entry: entry, pi: pi[entry.id])
                        }
                    }
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .paper(radius: 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        // 宽屏不把一行项目拉满整屏：名字与计数隔太远读不成一行
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private static let readableWidth: CGFloat = 760
}

/// 书架顶上的一行：图标、标题、说明，点进一页。
private struct ShelfLine: View {
    let route: Navigation.Route
    let symbol: String
    var tint: Color?
    let title: String
    let detail: String
    @Environment(\.palette) private var palette

    static let dividerInset: CGFloat = 48

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint ?? palette.ink2).frame(width: 22).accessibilityHidden(true)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                Text(detail).font(.body.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
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

/// 有没归类的想法时的提醒（注意色的图标）：点它去未归档整理。
private struct InboxReminder: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        ShelfLine(route: .inbox, symbol: "tray", tint: palette.attention, title: "未归档", detail: "\(count) 条待整理")
    }
}

/// 跨项目的任务："任务 2 进行中 · 3 待办"。
private struct TasksLine: View {
    let tasks: ShelfData.TaskCounts

    var body: some View {
        ShelfLine(route: .tasks, symbol: "checklist", title: "任务", detail: tasks.summary)
    }
}

private extension ShelfData.TaskCounts {
    /// "2 进行中 · 3 待办"；都做完了是"全部完成"。
    var summary: String {
        let parts = [inProgress > 0 ? "\(inProgress) 进行中" : nil, todo > 0 ? "\(todo) 待办" : nil].compactMap { $0 }
        return parts.isEmpty ? "全部完成" : parts.joined(separator: " · ")
    }
}

/// 置顶项目的大卡：图标、名称、目标、卡片数与未完成任务数、Pi 状态点。
private struct PinnedShelfCard: View {
    let entry: ShelfData.Entry
    let pi: PiShown?
    @Environment(\.palette) private var palette
    /// 项目图标随字号放大。
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 24

    var body: some View {
        NavigationLink(value: Navigation.Route.project(entry.project.id)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    ProjectGlyph(project: entry.project, size: glyph)
                    Spacer()
                    if let pi { PiStateDot(shown: pi, announces: true) }
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
        .projectActions(entry.project, radius: 20, pi: pi)
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

/// 书架的一行：项目（副标题是目标，没有目标时是最近一张卡）。
private struct ShelfRow: View {
    let entry: ShelfData.Entry
    let pi: PiShown?
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
                        if let pi { PiStateDot(shown: pi, size: 6, announces: true) }
                    }
                    Group {
                        if entry.goal?.isEmpty == false {
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
        .projectActions(entry.project, radius: 16, pi: pi)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let goal = entry.goal, !goal.isEmpty { return goal }
        if let latest = entry.latest { return "\(latest.title.nonEmpty ?? "空白卡片") · \(DateLabel.short(latest.date))" }
        return "还没有卡片"
    }
}
#endif
