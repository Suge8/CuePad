#if os(iOS)
import SwiftUI

struct ShelfScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            if let catalog = workspace.catalog {
                ProjectList(projects: catalog.projects, placesAtEnd: sizeClass == .compact) {
                    ChipFlow(spacing: Spacing.part) {
                        ProjectListPlace(title: "归档", icon: .archive, route: .archive)
                        ProjectListPlace(title: "回收站", icon: .trash, route: .trash)
                        if sizeClass == .compact {
                            ProjectListPlace(title: "设置", icon: .settings, route: .settings, alert: services.macAlert)
                        }
                    }
                }
            }
        }
        .refreshable { await services.syncNow() }
        .floatingHeader("项目") { NewProjectButton() }
    }
}

private struct NewProjectButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
    }
}
#endif
