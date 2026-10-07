#if os(iOS)
import Foundation
import Testing
@testable import CuePad

/// 标签栏布局的 ⌘K：有下拉搜索的只有项目页（聚焦它自己的）；其余页回到灵感根页，聚焦顶上一排的搜索框。
@MainActor
struct PageSearchKeyTests {
    private func navigation() -> Navigation {
        Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: "search-key-\(UUID())")!, launchArguments: [:]))
    }

    @Test func 项目页聚焦它自己的搜索_未归档与Agent页回到灵感根页() {
        let project = UUID()
        let navigation = navigation()
        navigation.projectsPath = [.project(project)]
        navigation.searchCurrentPage()
        #expect(navigation.pendingPageSearch == .project(project))
        #expect(navigation.projectsPath == [.project(project)])

        for start in [(Navigation.Tab.projects, [Navigation.Route.inbox]), (.agent, [])] {
            navigation.tab = start.0
            navigation.projectsPath = start.1
            navigation.pendingPageSearch = nil
            navigation.searchCurrentPage()
            #expect(navigation.tab == .projects)
            #expect(navigation.projectsPath.isEmpty)
            #expect(navigation.pendingPageSearch == .shelf)
        }
    }
}
#endif
