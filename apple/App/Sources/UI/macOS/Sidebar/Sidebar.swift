#if os(macOS)
import CueStore
import SwiftUI

/// 项目列表（宽屏会话条里"项目"一行的去处，主区）：右上新建项目，全部项目，末尾归档与回收站（同备忘录把"最近删除"排在文件夹末尾，会话条不为它们另起一排）。
struct ProjectShelf: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
                }
                ForEach(workspace.catalog?.projects ?? []) { project in
                    Button { workspace.show(.project(project.id)) } label: {
                        HStack(spacing: 12) {
                            ProjectGlyph(project: project)
                            Text(project.shownName)
                            Spacer()
                        }.padding(12).contentShape(.rect)
                    }
                    .buttonStyle(.row)
                    .contextMenu { ProjectActions(project: project, edit: { workspace.projectForm = .init(project: project) }) }
                }
                Divider().padding(.vertical, 4)
                place("归档", icon: .archive, route: .archive)
                place("回收站", icon: .trash, route: .trash)
            }.padding(16)
        }
    }

    private func place(_ title: LocalizedStringResource, icon: Icon, route: Route) -> some View {
        Button { workspace.show(route) } label: {
            HStack(spacing: 12) {
                Image(icon).frame(width: 20)
                Text(title)
                Spacer()
            }.padding(12).contentShape(.rect)
        }
        .buttonStyle(.row)
    }
}
#endif
