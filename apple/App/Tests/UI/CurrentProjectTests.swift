#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 保存的当前项目以 Store 的实际项目为准：失效（不存在或在回收站）时回落并纠正设置；新建的卡与任务只落在真实可见的位置。
@MainActor
struct CurrentProjectTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    /// 订阅项目目录（根视图的 `.task` 同一条路），等目录里有这些项目。
    private func observing(_ workspace: Workspace) -> Task<Void, Never> {
        Task { await workspace.observeCatalog() }
    }

    /// ⌘N 打开侧栏里此刻的第 N 个项目：项目顺序随最近活动与置顶变化，按下的那一刻按目录当前的顺序取，不能还绑在旧顺序上。
    @Test func 项目顺序变了之后_数字键打开的是侧栏里当下的第N个() async throws {
        _ = try await store.createProject(name: "A", color: "#000000")
        _ = try await store.createProject(name: "B", color: "#000000")
        let last = try await store.createProject(name: "C", color: "#000000")
        let workspace = Workspace(services: services)
        let catalog = observing(workspace)
        defer { catalog.cancel() }
        await eventually { workspace.catalog?.projects.count == 3 }

        try await store.updateProject(last.id) { $0.isPinned = true }
        await eventually { workspace.catalog?.projects.first?.id == last.id }
        workspace.showProject(number: 1)
        #expect(workspace.page == .project(last.id))
        workspace.showProject(number: 3)
        let third = try #require(workspace.catalog?.projects[2].id)
        #expect(workspace.page == .project(third) && third != last.id)
        workspace.showProject(number: 9)  // 没有第 9 个：不动
        #expect(workspace.page == .project(third))
    }

    @Test func 保存的项目不存在时_首屏是侧栏第一个有效项目_清掉失效的设置() async throws {
        _ = try await store.createProject(name: "A", color: "#000000")
        let pinned = try await store.createProject(name: "B", color: "#000000")
        try await store.updateProject(pinned.id) { $0.isPinned = true }
        services.settings.currentProject = UUID()
        let workspace = Workspace(services: services)
        let catalog = observing(workspace)
        defer { catalog.cancel() }

        await eventually { workspace.catalog?.projects.count == 2 && services.settings.currentProject == nil }

        #expect(workspace.page == .project(pinned.id))
        #expect(services.settings.currentProject == nil)
    }

    /// 第一次打开（没打开过项目）：首屏是项目目录顺序的第一个，由目录当场推出；项目陆续同步进来时跟着目录走，
    /// 不把最先到达的那个记成"上次打开"。只有用户切换项目才记下。
    @Test func 没打开过项目时_首屏跟着目录顺序走_不记下_用户切换才记() async throws {
        services.settings.currentProject = nil
        let workspace = Workspace(services: services)
        let catalog = observing(workspace)
        defer { catalog.cancel() }

        let first = try await store.createProject(name: "A", color: "#000000")
        await eventually { workspace.catalog?.projects.count == 1 }
        #expect(workspace.page == .project(first.id))

        let pinned = try await store.createProject(name: "B", color: "#000000")
        try await store.updateProject(pinned.id) { $0.isPinned = true }
        await eventually { workspace.catalog?.projects.first?.id == pinned.id }
        #expect(workspace.page == .project(pinned.id))
        #expect(services.settings.currentProject == nil)

        workspace.show(.project(first.id))
        #expect(services.settings.currentProject == first.id)
    }

    @Test func 当前项目进了回收站_回落到其余项目_没有项目时回落到未分类() async throws {
        let only = try await store.createProject(name: "A", color: "#000000")
        services.settings.currentProject = only.id
        let workspace = Workspace(services: services)
        try await store.trashProject(only.id)

        await workspace.reconcileCurrentProject()

        #expect(workspace.page == .inbox)
        #expect(services.settings.currentProject == nil)
    }

    @Test func 往失效项目存卡_卡落到未分类且可见() async throws {
        let trashed = try await store.createProject(name: "A", color: "#000000")
        try await store.trashProject(trashed.id)
        let workspace = Workspace(services: services)

        for target in [UUID(), trashed.id] {
            let card = try await workspace.createCard(body: "想法", in: target)
            #expect(card.projectID == nil)
        }
        #expect(try await store.cards(in: nil).map(\.body) == ["想法", "想法"])
    }

    @Test func 往失效项目加任务_任务归为全局() async throws {
        let workspace = Workspace(services: services)

        let task = try await workspace.createTask("跟进", in: UUID())

        #expect(task.projectID == nil)
    }

    @Test func 往有效项目存卡_落在该项目() async throws {
        let project = try await store.createProject(name: "A", color: "#000000")
        let workspace = Workspace(services: services)

        let card = try await workspace.createCard(body: "想法", in: project.id)

        #expect(card.projectID == project.id)
    }
}
#endif
#if os(macOS)

/// 竞态：界面选中项目之后、写入之前项目被删；Store 在写事务里拒绝（invalidProject），入口据此回落并提示，不吞错。
@MainActor
struct CurrentProjectRaceTests {
    let rig = TestApp()
    var services: AppServices { rig.services }

    @Test func 写入时项目已被删_卡片落到未分类_纠正当前项目并提示() async throws {
        let project = try await services.store.createProject(name: "A", color: "#000000")
        services.settings.currentProject = project.id
        let workspace = Workspace(services: services)
        let target = workspace.currentProject
        try await services.store.trashProject(project.id)

        let card = try await workspace.createCard(body: "想法", in: target)

        #expect(card.projectID == nil)
        #expect(try await services.store.cards(in: nil).map(\.id) == [card.id])
        #expect(services.settings.currentProject == nil)
        #expect(workspace.notice?.isError == true)
    }

    @Test func 写入时项目已被删_任务归为全局并提示() async throws {
        let project = try await services.store.createProject(name: "A", color: "#000000")
        let workspace = Workspace(services: services)
        try await services.store.trashProject(project.id)

        let task = try await workspace.createTask("跟进", in: project.id)

        #expect(task.projectID == nil)
        #expect(workspace.notice?.isError == true)
    }
}
#endif
