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
        let pi = PiSessionState.byProject(try store.piSessionStates())
        let entries = try SidebarOrder.projects(store.projects(), summaries: summaries).map { project in
            let latest = try store.search(SearchQuery(projects: [project.id]), limit: 1).cards.first
            return Entry(
                project: project, cardCount: counts[project.id] ?? 0, openTasks: openTasks[project.id] ?? 0,
                goal: try project.goalCardID.flatMap { try store.card($0) }.map { CardText($0.body).title },
                latest: latest.map { (CardText($0.body).title, $0.modifiedAt) }, pi: pi[project.id])
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
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: ShelfData?
    @State private var creating = false

    var body: some View {
        ScrollView {
            if let data { content(data) }
        }
        .background(palette.desk)
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建项目", systemImage: "folder.badge.plus") { creating = true }
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
        .sheet(isPresented: $creating) { ProjectFormSheet(project: nil) }
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
            TodayLink(count: data.todayCount)
            if data.entries.isEmpty {
                ContentUnavailableView {
                    Label("还没有项目", systemImage: "books.vertical")
                } actions: {
                    Button("新建项目") { creating = true }.buttonStyle(.glassProminent)
                }
            }
            if !pinned.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(pinned) { PinnedShelfCard(entry: $0) }
                }
            }
            if !recent.isEmpty || data.inboxCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "最近")
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 60) }
                            ShelfRow(route: .project(entry.project.id), entry: entry)
                        }
                        if data.inboxCount > 0 {
                            if !recent.isEmpty { Divider().padding(.leading, 60) }
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
                Image(systemName: "sun.max.fill").foregroundStyle(.orange).accessibilityHidden(true)
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
        .buttonStyle(PressableStyle())
        .accessibilityLabel("今天 \(count) 张卡片")
    }
}

/// 置顶项目的大卡：图标、名称、目标、卡片数与未完成任务数、Pi 状态点。
private struct PinnedShelfCard: View {
    let entry: ShelfData.Entry
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationLink(value: Navigation.Route.project(entry.project.id)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    ProjectGlyph(project: entry.project, size: 24)
                    Spacer()
                    if let pi = entry.pi { PiDot(state: pi) }
                }
                Text(entry.project.name).font(.title3.weight(.bold)).foregroundStyle(palette.ink).lineLimit(1)
                Group {
                    if let goal = entry.goal { Text("\(Image(systemName: "scope")) \(goal)") } else { Text("还没有目标") }
                }
                .font(.footnote)
                .foregroundStyle(entry.goal == nil ? palette.ink3 : palette.ink2)
                    .lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                ShelfCounts(entry: entry)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .paper(radius: 20)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.pi.map { "Pi \($0.label)" } ?? "")
    }
}

/// 卡片数与未完成任务数。
private struct ShelfCounts: View {
    let entry: ShelfData.Entry
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Text("\(entry.cardCount) 张")
            if entry.openTasks > 0 {
                Label("\(entry.openTasks)", systemImage: "checklist").accessibilityLabel("\(entry.openTasks) 条任务")
            }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(palette.ink3)
    }
}

/// 书架的一行：项目（副标题是目标，没有目标时是最近一张卡）或未归档。
private struct ShelfRow: View {
    let route: Navigation.Route
    let entry: ShelfData.Entry?
    var inboxCount = 0
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    private var stacked: Bool { typeSize.isAccessibilitySize }

    private var counts: some View {
        HStack(spacing: 10) {
            if let tasks = entry?.openTasks, tasks > 0 {
                Label("\(tasks)", systemImage: "checklist").labelStyle(.titleAndIcon)
                    .font(.caption.monospacedDigit()).foregroundStyle(palette.ink3)
                    .accessibilityLabel("\(tasks) 条任务")
            }
            Text("\(entry?.cardCount ?? inboxCount)").font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3)
                .accessibilityLabel("\(entry?.cardCount ?? inboxCount) 张卡片")
        }
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                ProjectGlyph(project: entry?.project, size: 17)
                    .frame(width: 36, height: 36)
                    .background(entry.map { Palette.projectTint($0.project.color).opacity(0.12) } ?? palette.fill, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry?.project.name ?? "未归档").font(.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(stacked ? 2 : 1)
                        if let pi = entry?.pi { PiDot(state: pi, size: 6) }
                    }
                    Group {
                        if entry?.goal?.isEmpty == false { Text("\(Image(systemName: "scope")) \(subtitle)") } else { Text(subtitle) }
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
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(kind: .row))
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry?.pi.map { "Pi \($0.label)" } ?? "")
    }

    private var subtitle: String {
        guard let entry else { return "待整理" }
        if let goal = entry.goal, !goal.isEmpty { return goal }
        if let latest = entry.latest { return "\(latest.title.nonEmpty ?? "空白卡片") · \(DateLabel.short(latest.date))" }
        return "还没有卡片"
    }
}
#endif
