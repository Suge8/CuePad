import CueStore
import SwiftUI

/// 项目目录沿用 ProjectCatalog 的置顶优先顺序，同一懒网格连续填充，不为分组重起一行。
/// 置顶在卡内标识；辅助入口在手机末尾、宽屏网格前，每张卡的身份始终是项目 id。
struct ProjectList<Places: View>: View {
    let projects: [Project]
    var placesAtEnd = false
    @ViewBuilder var places: Places
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 宽屏保留约 220pt 的完整插画，增宽时增加列数；少量项目也占同样的格子。
    private static var maximumWidth: CGFloat { 1080 }
    private static var columnWidth: CGFloat { 220 }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.item) {
            if !placesAtEnd { auxiliary }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.group) {
                ForEach(projects) { project in
                    ProjectListItem(project: project, summary: workspace.catalog?.summaries[project.id],
                                    openTasks: workspace.catalog?.taskCounts[project.id]?.open ?? 0)
                        .equatable()
                }
            }
            if placesAtEnd { auxiliary }
        }
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .safeAreaPadding(.horizontal, Spacing.page)
        .safeAreaPadding(.bottom, Spacing.section)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: projects.map(\.id))
    }

    private var auxiliary: some View {
        HStack(spacing: Spacing.part) { places }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var columns: [GridItem] {
        if typeSize >= .xxxLarge { return [GridItem(.flexible(), alignment: .topLeading)] }
        if placesAtEnd { return Array(repeating: GridItem(.flexible(), spacing: Spacing.group, alignment: .topLeading), count: 2) }
        return [GridItem(.adaptive(minimum: Self.columnWidth), spacing: Spacing.group, alignment: .topLeading)]
    }

}

private struct ProjectListItem: View, Equatable {
    let project: Project
    let summary: ProjectSummary?
    let openTasks: Int
    @Environment(Workspace.self) private var workspace
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.summary == rhs.summary && lhs.openTasks == rhs.openTasks
    }

    var body: some View {
        #if os(macOS)
        Button { workspace.show(.project(project.id)) } label: { label }
            .buttonStyle(PressStyle(.card))
            .contextMenu { ProjectActions(project: project) { workspace.projectForm = .init(project: project) } }
            .help(project.shownName)
        #else
        NavigationLink(value: Route.project(project.id)) { label }
            .buttonStyle(PressStyle(.card))
            .projectActions(project, cornerRadius: Radius.card)
        #endif
    }

    private var label: some View {
        ProjectCard(project: project, ideaCount: summary?.cardCount ?? 0, openTasks: openTasks,
                    modifiedAt: summary?.modifiedAt ?? project.modifiedAt)
    }
}

/// 项目列表的辅助入口紧靠名字，不把箭头推到整栏的另一端；触屏保留标准行高。
struct ProjectListPlace: View {
    let title: LocalizedStringResource
    let icon: Icon
    let route: Route
    var alert: SyncSummary?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            #if os(macOS)
            Button { workspace.show(route) } label: { label }
            #else
            NavigationLink(value: route) { label }
            #endif
        }
        .buttonStyle(.row)
        .accessibilityValue(alert?.title ?? "")
    }

    private var label: some View {
        HStack(spacing: Spacing.glyph) {
            Image(icon).font(Glyph.row).readerHidden(true)
            Text(title).font(Typography.secondary)
            if let alert { StatusDot(color: palette.color(alert.tone)) }
        }
        .foregroundStyle(palette.ink2)
        .frame(minHeight: RowMetrics.height)
        .contentShape(.rect)
    }
}
