#if os(macOS)
@testable import CueBridge
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueStore

/// 插入点在真实桥的 SessionLink.end 内、向 Agent 交出关闭之前；已经过执行器资格判断及桥的 TaskGroup 调度。
private final class InterleavingEndLink: SessionLink {
    let bridge: Bridge
    let beforeEnd: () async throws -> Void
    var handed = false

    init(bridge: Bridge, beforeEnd: @escaping () async throws -> Void) {
        self.bridge = bridge
        self.beforeEnd = beforeEnd
    }

    func end(_ id: Session.ID) async throws {
        try await beforeEnd()
        handed = true
        bridge.detach(id, reason: .closed(reason: "quit"))
    }
}

extension TaskFlowTests {
    @Test func 自动结束已受理但尚未交出_新借用和发送明确拒绝() async throws {
        let services = try #require(rig.services), workspace = Workspace(services: services)
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续语音", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        try await StateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "interleaved", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        try await workspace.complete(task.id)
        let end = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        let link = InterleavingEndLink(bridge: rig.bridge) { () async throws -> Void in
            #expect(try await self.store.deliveryRequest(end.id)?.status == .known(.executing))
            var refused = false
            do { try await self.store.bindSession("interleaved", to: borrower.id) }
            catch CueStoreError.sessionEnding { refused = true }
            #expect(refused, "自动结束已受理，借用不能假成功")
            await workspace.speak("继续处理", to: .session(
                SendTarget(kind: .piSession, name: "准备发布", ref: "interleaved"), host: TestApp.hostID, mode: .send, card: borrower.id)).value
            #expect(workspace.notice?.isError == true)
            #expect(try await self.store.deliveryRequests().filter { $0.mode == .known(.send) }.isEmpty)
        }
        let session = Session(
            id: "interleaved.1", sessionID: "interleaved", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory,
            terminal: TerminalIdentity(), state: .thinking, stateSince: .now)
        rig.bridge.attach(session, via: link)
        defer { rig.bridge.stop(); services.cancelBackgroundWork() }
        try await services.executor.start()
        #expect(try await store.outcome(of: end).status == .known(.succeeded))
        #expect(link.handed)
        #expect(try await store.card(borrower.id)?.piSessionID == nil)
        await services.executor.beginStop()()
    }
}
#endif
