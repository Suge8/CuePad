#if os(macOS)
import CueDispatch
import CueStore
import Foundation
import Testing
import AppKit
@testable import CuePad
@testable import CuePi

/// Mac 端的同步职责：唤醒时同步；把 Pi 会话状态写成同步记录；执行手机发来的投送请求。
@MainActor
struct MacSyncTests {
    let rig = Rig()
    var services: AppServices { rig.services }

    private func session(
        _ sessionID: String, cwd: String = "/work/app", state: PiAgentState = .thinking, pid: Int32 = 100
    ) -> CuePi.PiSession {
        CuePi.PiSession(
            id: "\(sessionID).\(pid)", sessionID: sessionID, sessionFile: nil, pid: pid, cwd: URL(filePath: cwd, directoryHint: .isDirectory),
            mode: "tui", model: nil, terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version, state: state, stateSince: .now)
    }

    private func changes(_ items: [PiSessionChange]) -> AsyncStream<PiSessionChange> {
        AsyncStream { continuation in
            items.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    // MARK: 唤醒

    @Test func 系统唤醒时立即同步() async {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        await eventually { rig.sync.started == 1 }

        rig.wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        await eventually { rig.sync.syncNows == 1 }
        #expect(rig.sync.syncNows == 1)
    }

    // MARK: Pi 状态记录

    @Test(arguments: [
        (PiAgentState.idle, PiWorkState.settled, String?.none),
        (.thinking, .thinking, nil),
        (.outputting, .outputting, nil),
        (.tool(name: "bash", running: ["bash"], detail: nil), .tool, "bash"),
        (.tool(name: "read", running: ["read"], detail: "README.md"), .tool, "read · README.md"),
        (.waitingUser(kind: "confirm", title: "覆盖文件？"), .waitingForUser, "覆盖文件？"),
        (.done(aborted: false), .settled, nil),
        (.error(message: "rate limit"), .error, "rate limit"),
    ])
    func Pi状态映射成同步记录的状态与说明(agent: PiAgentState, work: PiWorkState, detail: String?) async throws {
        try await services.consumePiChanges(changes([.appeared(session("s1", state: agent))]))

        let stored = try #require(try await services.store.piSessionStates().first)
        #expect(stored.state == .known(work))
        #expect(stored.detail == detail)
        #expect(stored.sessionID == "s1")
        #expect(stored.hostID == Rig.hostID)
    }

    @Test func 会话按工作目录归入项目_结束后记录删除() async throws {
        let project = try await services.store.createProject(name: "App", color: "#000000")
        try await services.store.setDirectory("/work", for: project.id)

        try await services.consumePiChanges(changes([.appeared(session("s1", cwd: "/work/app"))]))
        let stored = try #require(try await services.store.piSessionStates().first)
        #expect(stored.projectID == project.id)
        #expect(stored.title == "app")

        try await services.consumePiChanges(changes([.ended(session("s1"), reason: .disconnected)]))
        #expect(try await services.store.piSessionStates().isEmpty)
    }

    @Test func 启动时清掉这台Mac遗留的记录_不动别的Mac() async throws {
        let mine = PiStateRecorder(store: services.store, hostID: Rig.hostID)
        let other = PiStateRecorder(store: services.store, hostID: "mac-other")
        try await mine.update(sessionID: "old", state: .thinking)
        try await other.update(sessionID: "theirs", state: .thinking)

        try await services.resetPiState()

        #expect(try await services.store.piSessionStates().map(\.sessionID) == ["theirs"])
    }

    // MARK: 手机发来的投送请求

    private func awaitFinished(_ id: UUID) async throws -> DeliveryRequest {
        let watchdog = Task { try await Task.sleep(for: .seconds(10)); throw CancellationError() }
        defer { watchdog.cancel() }
        for try await request in services.store.observe([.deliveryRequests], { try $0.deliveryRequest(id) }) {
            if let request, request.status == .known(.succeeded) || request.status == .known(.failed) { return request }
        }
        throw CancellationError()
    }

    @Test func 手机的Pi直发请求在这台Mac执行并写回结果() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: false)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "做这件事", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: Rig.hostID, mode: .steer)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.succeeded))
        #expect(rig.channels.calls == [.send(PiMessage(text: "做这件事", whenBusy: .steer), "sess-1.100")])
        #expect(done.handledBy == Rig.hostID)
    }

    @Test func 手机的放进输入框请求只粘贴文字() async throws {
        rig.channels.bridgeIDs["sess-1"] = "sess-1.100"
        rig.channels.sessions["sess-1.100"] = PiSessionInfo(target: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), isBusy: false)
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "草稿", to: SendTarget(kind: .piSession, name: "app", ref: "sess-1"), on: Rig.hostID, mode: .paste)
        _ = try await awaitFinished(request.id)

        #expect(rig.channels.calls == [.paste("草稿", "sess-1.100")])
    }

    @Test func 目标会话已结束时请求失败并说明原因() async throws {
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .piSession, name: "gone", ref: "sess-gone"), on: Rig.hostID)
        let done = try await awaitFinished(request.id)

        #expect(done.status == .known(.failed))
        #expect(done.resultDetail?.contains("会话") == true)
        #expect(rig.channels.calls.isEmpty)
    }

    @Test func 通用投送请求按bundle投送_失败原因可读() async throws {
        rig.channels.dispatchError = DispatchError.accessibilityRequired
        try await services.startDeliveryExecutor()
        defer { services.cancelBackgroundWork() }

        let request = try await services.store.requestDelivery(
            "hi", to: SendTarget(kind: .app, name: "Ghostty", ref: "com.mitchellh.ghostty"), on: Rig.hostID)
        let done = try await awaitFinished(request.id)

        #expect(rig.channels.calls.contains(.dispatch(Payload(text: "hi"), .bundleID("com.mitchellh.ghostty"), submit: false)))
        #expect(done.status == .known(.failed))
        #expect(done.resultDetail?.contains("辅助功能") == true)
    }

    @Test func 本机标识由硬件UUID稳定派生_不含原值() {
        let first = HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001")
        #expect(first == HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000001"))
        #expect(first != HostIdentity.hostID(platformUUID: "A1B2C3D4-0000-4000-8000-000000000002"))
        #expect(first.hasPrefix("mac-") && !first.contains("A1B2C3D4"))
    }
}
#endif
