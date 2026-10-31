#if os(macOS)
import CueStore
import SwiftUI

/// CueSidebarCard 尚由共享组件持有，边距随该组件一起由 Owner 收口。
enum SidebarMetrics { static let edge: CGFloat = 10 }

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
            }.padding(16)
        }
    }
}
#endif
