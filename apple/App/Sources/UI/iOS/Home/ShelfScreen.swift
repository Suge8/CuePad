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

    var entries: [Entry]
    var inboxCount: Int
    var todayCount: Int
    var trashCount: Int

    static func read(from store: isolated CueStore, now: Date = .now, calendar: Calendar = .current) throws -> ShelfData {
        let summaries = try store.projectSummaries()
        let counts = Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0.cardCount) })
        let openTasks = Dictionary(grouping: try store.tasks(), by: \.projectID).mapValues(\.count)
        let entries = try SidebarOrder.projects(store.projects(), summaries: summaries).map { project in
            let latest = try store.search(SearchQuery(projects: [project.id]), limit: 1).cards.first
            return Entry(
                project: project, cardCount: counts[project.id] ?? 0, openTasks: openTasks[project.id] ?? 0,
                goal: try project.goalCardID.flatMap { try store.card($0) }.map { CardText($0.body).title },
                latest: latest.map { (CardText($0.body).title, $0.modifiedAt) })
        }
        let today = calendar.startOfDay(for: now)...now
        return ShelfData(
            entries: entries, inboxCount: counts[nil] ?? 0,
            todayCount: try store.search(SearchQuery(modifiedIn: today), limit: 0).totalCards,
            trashCount: try store.trashedProjects().count + store.trashedCards().count)
    }
}

/// iPhone 首页：项目书架。顶部一行"今天 · N 张"进入今天流；置顶项目是大卡，其余按最近排成行。
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
        }
        .sheet(isPresented: $creating) { ProjectFormSheet(project: nil) }
        .observing(services.store, [.projects, .cards, .tasks], into: $data, onError: workspace.fail) { try ShelfData.read(from: $0) }
    }

    @ViewBuilder
    private func content(_ data: ShelfData) -> some View {
        let pinned = data.entries.filter(\.project.isPinned)
        let recent = data.entries.filter { !$0.project.isPinned }
        VStack(alignment: .leading, spacing: 22) {
            NavigationLink(value: Navigation.Route.today) {
                HStack {
                    Label("今天 · \(data.todayCount) 张", systemImage: "sun.max")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .paper(radius: 14)
            }
            .buttonStyle(.plain)
            if data.entries.isEmpty {
                ContentUnavailableView {
                    Label("还没有项目", systemImage: "books.vertical")
                } description: {
                    Text("下方随手记的想法会先放进未归档；建一个项目来整理它们")
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
                    Text("最近").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 60) }
                            ShelfRow(route: .project(entry.project.id), project: entry.project, title: entry.project.name,
                                     subtitle: entry.latest.map { "\($0.title.isEmpty ? "空白卡片" : $0.title) · \(DateLabel.short($0.date))" },
                                     count: entry.cardCount)
                        }
                        if data.inboxCount > 0 {
                            if !recent.isEmpty { Divider().padding(.leading, 60) }
                            ShelfRow(route: .inbox, project: nil, title: "未归档", subtitle: "随手记先放在这里", count: data.inboxCount)
                        }
                    }
                    .paper(radius: 14)
                }
            }
            NavigationLink(value: Navigation.Route.trash) {
                Label(data.trashCount > 0 ? "回收站 · \(data.trashCount)" : "回收站", systemImage: "trash")
                    .font(.subheadline).foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

/// 置顶项目的大卡：图标、名称、目标、卡片数与未完成任务数。
private struct PinnedShelfCard: View {
    let entry: ShelfData.Entry
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationLink(value: Navigation.Route.project(entry.project.id)) {
            VStack(alignment: .leading, spacing: 8) {
                ProjectGlyph(project: entry.project, size: 22)
                Text(entry.project.name).font(.title3.weight(.bold)).foregroundStyle(palette.ink).lineLimit(1)
                Text(entry.goal ?? "还没有目标").font(.footnote)
                    .foregroundStyle(entry.goal == nil ? palette.ink3 : palette.ink2)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                HStack(spacing: 12) {
                    Text("\(entry.cardCount) 张")
                    if entry.openTasks > 0 { Label("\(entry.openTasks)", systemImage: "checklist").accessibilityLabel("\(entry.openTasks) 条任务") }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .paper(radius: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct ShelfRow: View {
    let route: Navigation.Route
    let project: Project?
    let title: String
    let subtitle: String?
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                ProjectGlyph(project: project, size: 17)
                    .frame(width: 34, height: 34)
                    .background(palette.fill, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(palette.ink3).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
