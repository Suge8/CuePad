#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Agent 页按项目筛选：能选的项目是在 Mac 上绑了代码目录的（会话按目录归入项目，没绑的不会有会话）；选择记在本机，下次打开还是它。
@MainActor
struct AgentFilterTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 能筛的项目_是在Mac上绑了代码目录的() async throws {
        let bound = try await store.createProject(name: "圆桌", color: "#000000")
        let unbound = try await store.createProject(name: "读书", color: "#000000")
        try await store.setDirectory("/Users/me/code/atlas", for: bound.id)
        try await store.publishDirectoryBindings(host: "mac-a", hostName: "MacBook")

        let list = try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, from: store)

        #expect(list.projects.contains(bound.id))
        #expect(!list.projects.contains(unbound.id))
    }

    @Test func 选过的项目记在本机_退出再回来还是它() {
        let suite = "agent-filter-\(UUID())"
        let project = UUID()
        AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:]).agentProject = project

        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:]).agentProject == project)
    }
}
#endif
