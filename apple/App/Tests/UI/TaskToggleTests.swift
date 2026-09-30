#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 勾选任务以 Store 的当前状态为准：界面手里的任务副本可能已经过时（列表还没刷新就又点了一次），
/// 切换不能按副本推算"下一个状态"，否则已勾的点了回不去、没勾的点了还是勾上。
@MainActor
struct TaskToggleTests {
    let rig = Rig()
    var services: AppServices { rig.services }

    @Test func 连续两次勾选同一任务_完成后又回到未完成_即使手里的副本已过时() async throws {
        let stale = try await services.store.createTask("续费域名")
        let workspace = Workspace(services: services)

        try await workspace.toggle(stale)
        #expect(try await services.store.completedTasks().map(\.id) == [stale.id])

        try await workspace.toggle(stale)
        #expect(try await services.store.tasks().map(\.id) == [stale.id])
        #expect(try await services.store.completedTasks().isEmpty)
    }
}
#endif
