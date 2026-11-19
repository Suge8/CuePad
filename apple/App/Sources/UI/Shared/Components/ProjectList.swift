import CueStore
import SwiftUI

/// 项目列表页：项目卡。归档、回收站与设置不在这一页里：宽屏在栏头（`WideShelfHeading`），手机在页头左边那颗"更多"里（`NarrowSidebarBar`）。
struct ProjectShelf: View {
    /// 手机：定成两列。
    var paired = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var maximumWidth: CGFloat { 1080 }
    private static var columnWidth: CGFloat { 220 }

    var body: some View {
        ScrollView {
            if let projects = workspace.catalog?.projects {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.group) {
                    ForEach(projects) { project in
                        ProjectListItem(project: project, summary: workspace.catalog?.summaries[project.id],
                                        openTasks: workspace.catalog?.taskCounts[project.id]?.open ?? 0)
                            .equatable()
                    }
                }
                .frame(maxWidth: Self.maximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .safeAreaPadding(.horizontal, Spacing.page)
                .safeAreaPadding(.bottom, Spacing.section)
                .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: projects.map(\.id))
            }
        }
    }

    private var columns: [GridItem] {
        if typeSize >= .xxxLarge { return [GridItem(.flexible(), alignment: .topLeading)] }
        if paired { return Array(repeating: GridItem(.flexible(), spacing: Spacing.group, alignment: .topLeading), count: 2) }
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
            .contextMenu { ProjectActions(project: project) }
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
