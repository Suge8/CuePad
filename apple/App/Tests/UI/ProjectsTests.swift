import CueStore
import Foundation
import Testing
@testable import CuePad

#if os(macOS)
@Suite(.releasesLibraries)
struct ProjectsTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    private func observing(_ workspace: Workspace) -> Task<Void, Never> {
        Task { await workspace.follow() }
    }

    @Test func 启动在Cue_主区留着项目列表_失效设置清掉_数字键按当下顺序取() async throws {
        _ = try await store.createProject(name: "A", color: "#000000")
        let pinned = try await store.createProject(name: "B", color: "#000000")
        try await store.updateProject(pinned.id) { $0.isPinned = true }
        services.settings.navigationPane = .projects
        services.settings.currentProject = UUID()
        let workspace = Workspace(services: services)
        let catalog = observing(workspace)
        defer { await catalog.stop() }
        try await eventually("目录读到三个项目，失效设置清掉") { workspace.catalog?.projects.count == 3 && services.settings.currentProject == nil }
        #expect(workspace.mainRoute == .shelf)

        services.settings.currentProject = pinned.id
        let fresh = Workspace(services: services)
        let freshCatalog = observing(fresh)
        defer { await freshCatalog.stop() }
        #expect(fresh.cueHome && fresh.mainRoute == .shelf && fresh.shownPane == nil)
        let last = try await store.createProject(name: "C", color: "#000000")
        try await store.updateProject(last.id) { $0.isPinned = true }
        try await eventually("fresh.catalog?.projects.first?.id == last.id") { fresh.catalog?.projects.first?.id == last.id }

        fresh.showProject(number: 1)
        #expect(fresh.mainRoute == .project(last.id) && fresh.shownPane == .projects && services.settings.currentProject == last.id)
        fresh.showProject(number: 3)
        let third = try #require(fresh.catalog?.projects[2].id)
        #expect(fresh.mainRoute == .project(third) && third != last.id)
        fresh.showProject(number: 9)
        #expect(fresh.mainRoute == .project(third))
        fresh.select(.shelf)
        #expect(fresh.mainRoute == .shelf && services.settings.currentProject == third)

        services.settings.currentProject = third
        for project in try await store.projects() where !project.isDefault { try await store.trashProject(project.id) }
        await #expect(throws: CueStoreError.defaultProjectUndeletable) { try await store.trashProject(Project.defaultID) }
        let only = Workspace(services: services)
        await only.reconcileCurrentProject()
        #expect(only.mainRoute == .shelf && services.settings.currentProject == nil)
    }

    @Test func 往失效项目存东西_落到默认项目_写入时被删则纠正并提示() async throws {
        let trashed = try await store.createProject(name: "A", color: "#000000")
        try await store.trashProject(trashed.id)
        let workspace = Workspace(services: services)

        for target in [UUID(), trashed.id] { #expect(try await workspace.createCard(body: "想法", in: target).projectID == Project.defaultID) }
        #expect(try await store.cards(in: Project.defaultID).map(\.body) == ["想法", "想法"])
        #expect(try await workspace.createTask("跟进", in: UUID()).projectID == Project.defaultID)
        let live = try await store.createProject(name: "B", color: "#000000")
        #expect(try await workspace.createCard(body: "想法", in: live.id).projectID == live.id)

        // 竞态：选中项目之后、写入之前项目被删——Store 在写事务里回落，入口按实际落点提示
        workspace.show(.project(live.id))
        let target = workspace.currentProject
        try await store.trashProject(live.id)
        let card = try await workspace.createCard(body: "晚了一步", in: try #require(target))
        #expect(card.projectID == Project.defaultID && services.settings.currentProject == nil && workspace.notice?.isError == true)
        workspace.notice = nil
        let doomed = try await store.createProject(name: "C", color: "#000000")
        try await store.trashProject(doomed.id)
        let task = try await workspace.createTask("跟进", in: doomed.id)
        #expect(task.projectID == Project.defaultID && workspace.notice?.isError == true)
    }
}
#endif

#if os(iOS)
@Suite(.releasesLibraries)
struct ProjectsNavigationTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func navigation() -> Workspace { Workspace(services: app.services) }

    @Test func 书架点进项目_新建落在这个项目_深链进项目() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let workspace = Workspace(services: app.services)

        let phone = navigation()
        phone.select(.shelf)  // 侧栏的“项目”
        phone.push(.project(project.id))  // 书架上的项目卡
        #expect(try await workspace.createTask("补重连用例", in: try #require(phone.currentProject)).projectID == project.id)
        phone.select(.progress)  // 侧栏的"进展"：不在哪个项目里
        #expect(phone.currentProject == nil)
        phone.open(DeepLink.project(project.id))
        #expect(phone.currentProject == project.id)
    }
}
#endif
