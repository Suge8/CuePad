#if os(iOS)
import CueStore
import SwiftUI

/// 书架：全部项目（侧栏项目区末尾的"全部项目"，侧栏只列置顶与最近的几个），右上"新建项目"。这一页只管灵感与任务，
/// Agent 的事都在 Cue 页（这里不写会话在做什么）：最上面是"正在推进"：进行中的任务排在一张纸上（点开推入任务页），
/// 标题右边是全部任务的计数、点它进任务页；没有进行中的任务时，只剩一行"任务 · N 待办"做入口。有没归类的灵感时一行提醒去整理；
/// 置顶项目是大卡，其余按最近排成行。宽屏（iPad）放得下时，上面这几样与置顶项目并排两栏。
struct ShelfScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var data: ShelfData?

    var body: some View {
        ScrollView {
            if let data, let catalog = workspace.catalog { content(data, catalog) }
        }
        .refreshable { await services.syncNow() }
        .floatingHeader(SidebarOutline.Entry.allProjects.title, detail: workspace.catalog.map { "\($0.projects.count) 个项目" } ?? "") {
            Button("新建项目", systemImage: "folder.badge.plus") { navigation.projectForm = .init() }
        }
        .observing(services.store, into: $data, onError: workspace.fail) {
            try ShelfData.read(from: $0)
        }
    }

    @ViewBuilder
    private func content(_ data: ShelfData, _ catalog: ProjectCatalog) -> some View {
        let entries = catalog.shelfEntries
        let pinned = entries.filter(\.project.isPinned)
        let recent = entries.filter { !$0.project.isPinned }
        let now = data.now(projects: catalog.projects)
        let wide = sizeClass == .regular && !typeSize.isAccessibilitySize
        LazyVStack(alignment: .leading, spacing: Self.sectionGap) {
            if entries.isEmpty && catalog.unfiledCount == 0 {
                VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, catalog) }
                EmptyShelf { navigation.projectForm = .init() }
            } else if wide, !pinned.isEmpty, hasLead(data, catalog) {
                // 宽屏两栏：左边现在要干的，右边置顶项目；放不下两栏时上下排
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, catalog) }.frame(maxWidth: .infinity)
                        // 右栏的大卡按宽度排：窄时一列叠放，宽时两列
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.pinnedMinWidth), spacing: 12)], spacing: 12) {
                            ForEach(pinned) { PinnedShelfCard(entry: $0, now: now[$0.id]) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(minWidth: Self.twoColumnWidth, idealWidth: Self.twoColumnWidth, maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: Self.sectionGap) {
                        VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, catalog) }
                        pinnedGrid(pinned, columns: min(pinned.count, 4), now: now)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Self.leadGap) { lead(data, catalog) }
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
        // 宽屏不把一行项目拉满整屏：名字与计数隔太远读不成一行
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private static let readableWidth: CGFloat = 1080
    /// 两级节奏：现在要干的几样（正在推进、未分类）之间紧一些，与置顶、最近这些段之间松一些。
    private static let leadGap: CGFloat = 16
    private static let sectionGap: CGFloat = 28
    /// 两栏各至少这么宽才并排（左栏放得下正在推进的一行任务，右栏放得下一张置顶大卡）。
    private static let twoColumnWidth: CGFloat = 640
    private static let pinnedMinWidth: CGFloat = 220

    private func hasLead(_ data: ShelfData, _ catalog: ProjectCatalog) -> Bool {
        !data.active.isEmpty || catalog.shelfTasks != nil || catalog.unfiledCount > 0
    }

    /// 现在要干的：正在推进（没有时是任务入口）、未分类。
    @ViewBuilder
    private func lead(_ data: ShelfData, _ catalog: ProjectCatalog) -> some View {
        let tasksLine = data.active.isEmpty ? catalog.shelfTasks : nil
        let unfiled = catalog.unfiledCount
        if !data.active.isEmpty { ActiveTasks(tasks: data.active, more: data.activeMore, counts: catalog.shelfTasks).transition(Motion.item) }
        if unfiled > 0 || tasksLine != nil {
            VStack(spacing: 0) {
                if let tasksLine { TasksLine(tasks: tasksLine) }
                if unfiled > 0, tasksLine != nil { Divider().padding(.leading, ShelfLine.dividerInset) }
                if unfiled > 0 { UnfiledReminder(count: unfiled) }
            }
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .paper(radius: 16)
        }
    }

    /// 置顶大卡按行排：每行 `columns` 张平分整行，最后一行不满时那几张也平分整行，不留空格；最后一行只剩一张时它占满整行、
    /// 横着排成矮的一条（`wide`）——不让单出来的那张（常是最不活跃、甚至空的项目）成为首屏最大的一块。
    /// 一行里的卡同高。置顶的不多，不用懒加载。
    private func pinnedGrid(_ pinned: [ShelfEntry], columns: Int, now: [UUID: ProjectNow]) -> some View {
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

}

/// 书架顶上的一行：图标、标题、说明，点进一页。
private struct ShelfLine: View {
    let route: Route
    let symbol: String
    let title: String
    let detail: Dotted
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
private struct UnfiledReminder: View {
    let count: Int

    var body: some View {
        ShelfLine(route: .unfiled, symbol: "tray", title: CaptureCopy.unfiled, detail: "\(count) 条待整理")
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
    let entry: ShelfEntry
    let now: ProjectNow?
    var wide = false
    @Environment(\.palette) private var palette
    /// 项目图标随字号放大。
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 22

    private static let radius: CGFloat = 20

    var body: some View {
        let wash = palette.projectWash(entry.project.color)
        NavigationLink(value: Route.project(entry.project.id)) {
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
                    colors: [wash, wash.opacity(0)],
                    startPoint: wide ? .leading : .top, endPoint: .center),
                in: .rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
        }
        .buttonStyle(PressStyle(.card))
        .projectActions(entry.project, radius: Self.radius, pi: nil)
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
    let entry: ShelfEntry
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
        NavigationLink(value: Route.project(entry.project.id)) {
            HStack(spacing: 12) {
                // 辅助功能大字号下图标并进名称一行，文字从行首开始，不空出一列图标宽
                if !stacked {
                    ProjectGlyph(project: entry.project, size: 17)
                        .frame(width: Self.tile, height: Self.tile)
                        .background(palette.projectWash(entry.project.color), in: .rect(cornerRadius: 10))
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
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Self.horizontalPadding).padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .background(palette.paper)
        .projectActions(entry.project, radius: 16, pi: nil)
        .accessibilityElement(children: .combine)
    }
}

/// 正在推进：一屏的重点。进行中的任务排在一张纸上，点开推入任务页；标题右边是全部任务的计数，点它进任务页——
/// 单独一行"任务 · N 进行中"会与下面这几行重复报进行中，所以并进标题。行与行之间靠留白分开，不画线。
private struct ActiveTasks: View {
    let tasks: [TaskBoard.ActiveTask]
    let more: Int
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
                ForEach(tasks) { ActiveTaskRow(item: $0).transition(Motion.item) }
                if more > 0 { moreRow }
            }
            .padding(.vertical, 6)
            .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
        }
    }

    /// 纸底的一行：标题上的进行中数比列出的多几项。
    private var moreRow: some View {
        NavigationLink(value: Route.tasks) {
            HStack(spacing: 4) {
                Text("还有 \(more) 项")
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(.subheadline).foregroundStyle(palette.ink3)
            .padding(.leading, ActiveTaskRow.textInset).padding(.trailing, 16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
    }

    private var title: some View {
        Text("正在推进").font(.title3.weight(.bold)).foregroundStyle(palette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func allTasks(_ counts: TaskCounts) -> some View {
        NavigationLink(value: Route.tasks) {
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

/// 正在推进的一行：进行中的圈（全 App 同一个 `TaskRingView`）、标题，下面一行是所在项目与步骤做了几个；
/// 有正在做的步骤时再一行写它——圈小一号、字小一号，与任务页里步骤的样子相同：一眼看到这件事走到了哪一步。
private struct ActiveTaskRow: View {
    let item: TaskBoard.ActiveTask
    @Environment(Navigation.self) private var navigation
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var scaledRing: CGFloat = 20

    /// 圆圈随字号放大，到辅助字号封顶：再大只会把标题往右挤。
    private var ring: CGFloat { min(scaledRing, 28) }
    private static let gap: CGFloat = 12
    /// 字的左缘（"还有 N 项"与它对齐）。
    static let textInset: CGFloat = 16 + 20 + gap

    var body: some View {
        let task = item.task
        Button { navigation.push(.card(task.id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
                TaskRingView(status: .inProgress, done: false, size: ring).relaySpot(task: task.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title.textGlyphs).font(.headline).foregroundStyle(palette.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2).multilineTextAlignment(.leading)
                    meta
                    if let step = item.step { stepLine(step) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .contextMenu { CardActions(card: task) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speech)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开任务")
    }

    private var project: Project? { workspace.catalog?.project(item.task.projectID) }

    @ViewBuilder private var meta: some View {
        if project != nil || item.steps != nil {
            HStack(spacing: 6) {
                if let project {
                    HStack(spacing: 4) {
                        ProjectGlyph(project: project, size: 11)
                        Text(project.name)
                    }
                }
                if project != nil, item.steps != nil { Dot() }
                if let steps = item.steps { Text(TaskCopy.progress(steps)).monospacedDigit() }
            }
            .font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
        }
    }

    /// 正在做的那一步：与任务页里的步骤同一个样子（小一号的圈与字）。
    private func stepLine(_ step: Card) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TaskRingView(status: step.status, done: false, size: TaskMetrics.stepRing - 2).relaySpot(task: step.id)
            Text(step.title.textGlyphs).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .padding(.top, 2)
    }

    private var speech: String {
        [item.task.title, project?.name, item.steps.map(TaskCopy.progress), item.step.map { "正在做 \($0.title)" }]
            .compactMap { $0 }.joined(separator: "，")
    }
}
#endif
