#if os(macOS)
import CueStore
import SwiftUI

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
