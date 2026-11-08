#if os(macOS)
import SwiftUI

/// 会话条「项目」的去处：共用项目目录，新建在主区栏头，归档与回收站紧邻列表组头。
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
