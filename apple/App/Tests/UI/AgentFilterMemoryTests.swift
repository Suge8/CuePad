#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Agent 页的项目筛选怎么定：在 Agent 页选的记在本机、重开后还筛着它；从项目页进来先筛该项目、在那里换的不记；
/// 记住的项目进了回收站时回到全部。
@MainActor
struct AgentFilterMemoryTests {
    let app = TestApp()

    private func catalog(_ projects: [Project]) -> ProjectCatalog {
        ProjectCatalog(projects: projects, cardCounts: [:], directories: [:], bindings: [])
    }

    private func navigation(_ suite: String) -> Navigation {
        Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:]))
    }

    @Test func 在Agent页选的项目_重开后还筛着它() async throws {
        let table = try await app.services.store.createProject(name: "圆桌", color: "#000000")
        let suite = "agent-filter-\(UUID())"
        navigation(suite).chooseAgentFilter(table.id, entered: nil)

        #expect(navigation(suite).agentFilter(entered: nil, catalog: catalog([table])) == table.id)
    }

    @Test func 从项目页进来先筛该项目_在那里换的不记() async throws {
        let table = try await app.services.store.createProject(name: "圆桌", color: "#000000")
        let site = try await app.services.store.createProject(name: "个人网站", color: "#000000")
        let nav = navigation("agent-filter-\(UUID())")
        nav.chooseAgentFilter(table.id, entered: nil)

        #expect(nav.agentFilter(entered: site.id, catalog: catalog([table, site])) == site.id)
        nav.chooseAgentFilter(nil, entered: site.id)
        #expect(nav.agentFilter(entered: nil, catalog: catalog([table, site])) == table.id)
    }

    @Test func 记住的项目进了回收站_回到全部() async throws {
        let table = try await app.services.store.createProject(name: "圆桌", color: "#000000")
        let nav = navigation("agent-filter-\(UUID())")
        nav.chooseAgentFilter(table.id, entered: nil)

        #expect(nav.agentFilter(entered: nil, catalog: catalog([])) == nil)
    }
}
#endif
