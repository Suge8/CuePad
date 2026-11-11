import CueStore
import SwiftUI

struct ProjectList<Places: View>: View {
    let projects: [Project]
    var placesAtEnd = false
    @ViewBuilder var places: Places
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
