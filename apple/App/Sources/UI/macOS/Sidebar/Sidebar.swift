#if os(macOS)
import SwiftUI

struct ProjectShelf: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollView {
            if let projects = workspace.catalog?.projects {
                ProjectList(projects: projects) {
                    HStack(spacing: Spacing.part) {
                        ProjectListPlace(title: "归档", icon: .archive, route: .archive)
                        ProjectListPlace(title: "回收站", icon: .trash, route: .trash)
                    }
                }
            }
        }
        .safeAreaPadding(.top, Bars.contentGap)
    }
}
#endif
