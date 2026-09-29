#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 保存的当前项目以 Store 的实际项目为准：失效（不存在或在回收站）时回落并纠正设置；新建的卡与任务只落在真实可见的位置。
@MainActor
struct CurrentProjectTests {
    let rig = Rig()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    @Test func 保存的项目不存在时_回落到侧栏第一个有效项目并纠正设置() async throws {
        _ = try await store.createProject(name: "A", color: "#000000")
        let pinned = try await store.createProject(name: "B", color: "#000000")
        try await store.updateProject(pinned.id) { $0.isPinned = true }
        services.settings.currentProject = UUID()
        let workspace = Workspace(services: services)

        await workspace.reconcileCurrentProject()

        #expect(workspace.page == .project(pinned.id))
        #expect(services.settings.currentProject == pinned.id)
    }

    @Test func 当前项目进了回收站_回落到其余项目_没有项目时回落到未归档() async throws {
        let only = try await store.createProject(name: "A", color: "#000000")
        services.settings.currentProject = only.id
        let workspace = Workspace(services: services)
        try await store.trashProject(only.id)

        await workspace.reconcileCurrentProject()

        #expect(workspace.page == .inbox)
        #expect(services.settings.currentProject == nil)
    }

    @Test func 往失效项目存卡_卡落到未归档且可见() async throws {
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
