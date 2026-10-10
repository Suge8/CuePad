#if os(iOS)
import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// Agent 页的项目筛选怎么定：标签页选的记在本机、重开后还筛着它；从项目页进来先筛该项目、在那里换的不记；
/// 记住的项目进了回收站时回到全部。
@MainActor
struct AgentFilterMemoryTests {
    let app = TestApp()

    private func catalog(_ projects: [Project]) -> ProjectCatalog {
        ProjectCatalog(projects: projects, cardCounts: [:], openTasks: [:], directories: [:], bindings: [])
    }

    private func navigation(_ suite: String) -> Navigation {
        Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:]))
    }

    @Test func 在Agent页选的项目_重开后还筛着它() async throws {
        let table = try await app.services.store.createProject(name: "圆桌", color: "#000000")
        let suite = "agent-filter-\(UUID())"
        navigation(suite).chooseAgentFilter(table.id)

        #expect(navigation(suite).agentFilter(catalog: catalog([table])) == table.id)
    }

    @Test func 从项目页进来先筛该项目_在那里换的不记() async throws {
        let table = try await app.services.store.createProject(name: "圆桌", color: "#000000")
        let site = try await app.services.store.createProject(name: "个人网站", color: "#000000")
        let nav = navigation("agent-filter-\(UUID())")
        let projects = catalog([table, site])
        nav.chooseAgentFilter(table.id)

        var pushed = AgentFilter(entered: site.id)
        #expect(pushed.current(in: nav, catalog: projects) == site.id)
        pushed.choose(nil, in: nav)
        #expect(pushed.current(in: nav, catalog: projects) == nil)
        #expect(AgentFilter(entered: nil).current(in: nav, catalog: projects) == table.id)  // 标签页的筛选没被推入页改动

        var tab = AgentFilter(entered: nil)
        tab.choose(site.id, in: nav)
        #expect(nav.agentFilter(catalog: projects) == site.id)
    }

    /// 页面读的是 AppSettings 本身：选的那一刻页面就跟着变，不用再留一份页面自己的"点过的筛选"。
    @Test func 选的项目是可观察的() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "agent-filter-\(UUID())")!, launchArguments: [:])
        let changed = Mutex(false)
        withObservationTracking { _ = Navigation(settings: settings).agentFilter(catalog: catalog([])) } onChange: {
            changed.withLock { $0 = true }
        }
        settings.agentProject = UUID()
        #expect(changed.withLock { $0 })
    }

    @Test func 记住的项目进了回收站_回到全部() async throws {
        let table = try await app.services.store.createProject(name: "圆桌", color: "#000000")
        let nav = navigation("agent-filter-\(UUID())")
        nav.chooseAgentFilter(table.id)

        #expect(nav.agentFilter(catalog: catalog([])) == nil)
    }
}
#endif
