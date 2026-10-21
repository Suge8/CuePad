#if os(iOS)
import CueStore
import SwiftUI

/// 项目页（iPhone 底部一排的"项目"；宽屏侧栏项目区末尾的"全部项目"，侧栏只列置顶与最近的几个），右上"新建项目"。
/// 只排项目（任务的事在任务页）：置顶项目是纸卡（`pinnedGrid`），其余排成一张纸上的行，长相同侧栏的项目行。卡与行的"此刻"同侧栏一条规则（`ProjectNow.byProject`：会话的事、进行中的任务、介绍）。
/// 窄屏（iPhone）没有侧栏，末尾一组归档、回收站、设置（同步到不了 Mac 时设置那一行带点，`AppServices.macAlert`）推在这一页上；宽屏这一组在侧栏里，这里不放。
struct ShelfScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 各项目的进行中任务，最近开始的在前（"此刻"的一档，同侧栏）。
    @State private var leading: [UUID: [ProjectNow.InProgress]]?

    private var narrow: Bool { sizeClass == .compact }

    var body: some View {
        ScrollView {
            if let catalog = workspace.catalog, let leading { content(catalog, leading: leading) }
        }
        .refreshable { await services.syncNow() }
        .floatingHeader(narrow ? "项目" : SidebarOutline.Entry.allProjects.title, detail: workspace.catalog.map { "\($0.projects.count) 个项目" } ?? "") {
            Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
        }
        .observing(services.store, into: $leading, onError: workspace.fail) { ProjectNow.leading(try $0.startedTasks()) }
    }

    private func content(_ catalog: ProjectCatalog, leading: [UUID: [ProjectNow.InProgress]]) -> some View {
        let pinned = catalog.projects.filter(\.isPinned)
        let rest = catalog.projects.filter { !$0.isPinned }
        // "此刻"在数据变化时算一次，卡与行只拿结果
        let now = ProjectNow.byProject(catalog.projects, sessions: services.liveSessions.items, tasks: leading, shown: workspace.shown)
        let wide = !narrow && !typeSize.isAccessibilitySize
        return LazyVStack(alignment: .leading, spacing: Self.sectionGap) {
            if !pinned.isEmpty {
                // 置顶卡平分整行：iPhone 至多两列，宽屏至多四列，不留一排窄卡靠左
                pinnedGrid(pinned, columns: typeSize.isAccessibilitySize ? 1 : min(pinned.count, wide ? 4 : 2), now: now)
            }
            if !rest.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rest) { ShelfRow(project: $0, count: catalog.cardCounts[$0.id] ?? 0, now: now[$0.id]) }
                }
                .padding(.vertical, Self.paperInset)
                .rowPaper(radius: Self.radius)
            }
            if narrow { ShelfFooter() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .animation(Motion.snappy, value: catalog.projects.map(\.id))
        // 宽屏不把一行项目拉满整屏：名字与计数隔太远读不成一行
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private static let readableWidth: CGFloat = 1080
    private static let sectionGap: CGFloat = 20
    static let radius: CGFloat = 20
    /// 纸的上下沿比行间多留的白。
    static let paperInset: CGFloat = 6

    /// 置顶卡按行排：每行 `columns` 张平分整行，最后一行不满时那几张也平分整行，不留空格；最后一行只剩一张时它占满整行、
    /// 横着排成矮的一条（`wide`）——不让单出来的那张（常是最不活跃、甚至空的项目）成为首屏最大的一块。
    /// 一行里的卡同高。置顶的不多，不用懒加载。
    private func pinnedGrid(_ pinned: [Project], columns: Int, now: [UUID: ProjectNow]) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: pinned.count, by: columns)), id: \.self) { start in
                let row = pinned[start..<min(start + columns, pinned.count)]
                HStack(spacing: 12) {
                    ForEach(row) { PinnedShelfCard(project: $0, now: now[$0.id], wide: row.count == 1 && columns > 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 置顶项目的纸卡：项目色从上沿淡下来的一层底、图标、名字、介绍，再一行"此刻"（会话的事或进行中的任务；
/// "此刻"落到介绍那一档时不再写一遍）。`wide`：一行里单出来的那张占满整行，横着排成矮的一条，图标在左。
private struct PinnedShelfCard: View {
    let project: Project
    let now: ProjectNow?
    var wide = false
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 22

    private static let radius: CGFloat = 20

    var body: some View {
        let wash = palette.projectWash(project.color)
        NavigationLink(value: Route.project(project.id)) {
            Group {
                if wide {
                    HStack(spacing: 12) {
                        ProjectGlyph(project: project, size: glyph)
                        VStack(alignment: .leading, spacing: 4) { lines }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ProjectGlyph(project: project, size: glyph).padding(.bottom, 8)
                        lines
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 渐变只铺在填充上（不用渐变描边，见 docs/ui.md「渲染性能约束」）
            .background(
                LinearGradient(colors: [wash, wash.opacity(0)], startPoint: wide ? .leading : .top, endPoint: .center),
                in: .rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
        }
        .buttonStyle(PressStyle(.card))
        .projectActions(project, radius: Self.radius, pi: now?.shown)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var lines: some View {
        Text(project.name).font(.title3.weight(.bold)).foregroundStyle(palette.ink).lineLimit(1)
        if let intro = project.intro?.nonEmpty {
            Text(intro).font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(1)
        }
        if let now, now.source != .intro { ProjectNowLine(now: now, font: Typography.meta) }
    }
}

/// 项目的一行，长相同侧栏的项目行：图标、名字、灵感数，下面一行"此刻"（`ProjectNowLine` 一直占着这一行的高度，状态出现、消失时列表不跳）。
/// 辅助字号下名字独占一行、可换行，灵感数排到下一行。
private struct ShelfRow: View {
    let project: Project
    let count: Int
    let now: ProjectNow?
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        NavigationLink(value: Route.project(project.id)) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))) {
                        Text(project.name).font(.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(stacked ? 3 : 1)
                        if !stacked { Spacer(minLength: 4) }
                        if count > 0 {
                            Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3).counting(count)
                                .accessibilityLabel("\(count) 条灵感")
                        }
                    }
                    ProjectNowLine(now: now, font: .footnote)
                }
            } icon: {
                ProjectGlyph(project: project, size: glyph)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .projectActions(project, radius: ShelfScreen.radius, pi: now?.shown)
        .accessibilityElement(children: .combine)
    }
}

/// 窄屏末尾那一组：归档、回收站、设置（`SidebarOutline.footer`，同侧栏底部），点了推在项目页上。
private struct ShelfFooter: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SidebarOutline.footer, id: \.self) { entry in
                ShelfLine(route: entry.route, icon: entry.icon, title: entry.title, alert: entry == .settings ? services.macAlert : nil)
            }
        }
        .padding(.vertical, ShelfScreen.paperInset)
        .rowPaper(radius: ShelfScreen.radius)
    }
}

/// 末尾那一组的一行：图标、名字，行尾是同步到不了 Mac 的点（只有设置）、条数与箭头，点进一页。
private struct ShelfLine: View {
    let route: Route
    let icon: Icon
    let title: String
    var alert: SyncSummary?
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                IconImage(icon).font(.system(size: glyph)).foregroundStyle(palette.ink).frame(minWidth: 22).accessibilityHidden(true)
                Text(title).foregroundStyle(palette.ink)
                Spacer(minLength: 8)
                if let alert { Circle().fill(palette.color(alert.tone)).frame(width: 7, height: 7).accessibilityHidden(true) }
                Image(.forward).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .accessibilityElement(children: .combine)
        .accessibilityValue(alert?.title ?? "")
    }
}
#endif
