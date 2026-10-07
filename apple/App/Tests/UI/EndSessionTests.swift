#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Agent 页"结束会话"：进度只来自发给会话的结束请求（Store 里那一条），会话页与列表读同一处。
/// 没能结束时那一行写 Mac 给的原因；结束了会话进"历史"、不留进度；还在路上时再点不会再发一条。
@MainActor
struct EndSessionTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func live(_ id: String) async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: id, state: .waitingForUser, title: id)
        return try #require(try await store.allPiSessionStates().first { $0.sessionID == id })
    }

    /// 那台 Mac：执行器领到结束请求后按 `handle` 的结果写回，等到请求有结果。
    private func macHandlesEnd(of session: PiSessionState, _ handle: @escaping @Sendable (DeliveryRequest) async -> DeliveryOutcome) async throws {
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("执行器意外上报：\($0)") }, handler: handle)
        try await executor.start()
        defer { Task { await executor.stop() } }
        let request = try #require(try await store.deliveryRequests(toSession: session.sessionID).last)
        _ = try await app.services.outcome(of: request.id)
    }

    private func list() async throws -> PiSessionList {
        try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, from: store)
    }

    @Test func 没能结束_那一行写Mac给的原因() async throws {
        let session = try await live("deploy")
        let workspace = Workspace(services: app.services, holder: SceneContext())

        await workspace.end(session)
        #expect(try await list().ends[session.id]?.isOpen == true)

        try await macHandlesEnd(of: session) { _ in .failed("会话没有按时结束，可能还在等你在终端里处理") }

        let end = try #require(try await list().ends[session.id])
        #expect(end.failure == "会话没有按时结束，可能还在等你在终端里处理")
    }

    @Test func 结束了_会话进历史且不留进度() async throws {
        let session = try await live("deploy")
        let workspace = Workspace(services: app.services, holder: SceneContext())
        let store = store

        await workspace.end(session)
        try await macHandlesEnd(of: session) { _ in
            try? await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "deploy", state: .ended, title: "deploy")
            return .succeeded
        }

        let list = try await list()
        #expect(list.now.map(\.id).contains(session.id) == false)
        #expect(list.ended.map(\.id).contains(session.id))
        #expect(list.ends[session.id] == nil)
    }

    @Test func 还在路上时再点_不再发第二条() async throws {
        let session = try await live("deploy")
        let workspace = Workspace(services: app.services, holder: SceneContext())

        await workspace.end(session)
        await workspace.end(session)

        let ends = try await store.deliveryRequests(toSession: "deploy").filter { $0.mode == .known(.end) }
        #expect(ends.count == 1)
    }
}
#endif
