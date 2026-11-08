#if os(macOS)
import CueStore
import SwiftUI

/// 项目列表（会话条「项目」那一行的去处，主区；新建项目在栏头右边，`MainColumn`）：置顶的一张纸、其余一张纸，末尾一张纸放归档与回收站
/// （同备忘录把"最近删除"排在文件夹末尾，会话条不为它们另起一排）。每行是标准的点进一页的行（`LinkRow`），图标一列，字从同一条竖线起；
/// 点了进项目页，右键是项目操作。同 iPad 的书架（`ShelfScreen`）只排项目，在发生什么在进展页；行宽不过阅读栏宽。
struct ProjectShelf: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let projects = workspace.catalog?.projects {
                    let pinned = projects.filter(\.isPinned)
                    let rest = projects.filter { !$0.isPinned }
                    if !pinned.isEmpty { paper { ForEach(pinned, content: row) } }
                    if !rest.isEmpty { paper { ForEach(rest, content: row) } }
                    paper {
                        place("归档", icon: .archive, route: .archive)
                        place("回收站", icon: .trash, route: .trash)
                    }
                }
            }
            .animation(Motion.nudge, value: workspace.catalog?.projects.map(\.id))
            .frame(maxWidth: Spacing.reading, alignment: .leading)
            .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaPadding(.top, Bars.contentGap)
    }

    private func paper(@ViewBuilder rows: () -> some View) -> some View {
        VStack(spacing: 0) { rows() }.rowPaper(cornerRadius: Radius.block)
    }

    private func row(_ project: Project) -> some View {
        Button { workspace.show(.project(project.id)) } label: {
            LinkRow(title: Text(verbatim: project.shownName)) { ProjectGlyph(project: project) }
        }
        .buttonStyle(.row)
        .contextMenu { ProjectActions(project: project, edit: { workspace.projectForm = .init(project: project) }) }
    }

    private func place(_ title: LocalizedStringResource, icon: Icon, route: Route) -> some View {
        Button { workspace.show(route) } label: {
            LinkRow(title: Text(title)) { Image(icon) }
        }
        .buttonStyle(.row)
    }
}
#endif
