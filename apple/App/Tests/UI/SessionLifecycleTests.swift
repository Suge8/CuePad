#if os(macOS)
@testable import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SessionLifecycleTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func record() async throws -> SessionState {
        try await StateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "atlas", state: .settled, title: "/", directory: "/")
        return try #require(try await store.allPiSessionStates().first)
    }

    @Test func 结束同一会话的所有宿主_不按名字或目录隐藏外部RPC() async throws {
        let first = try await app.host.connect("atlas", cwd: "/")
        let other = FakeExtension(
            directory: app.socketDirectory, sessionID: "atlas", pid: Int32.max - 1,
            options: .init(cwd: "/", mode: "rpc"))
        other.onCommand = { [weak other] _, command in
            if command["t"] as? String == "end" { other?.closeAfterReply(bye: "quit") }
            return ["ok": true]
        }
        try other.start()
        defer { other.crash() }
        try await eventually("两个宿主都可见") { app.pi.sessions.count == 2 }
        let session = try await record()
        try await app.services.executor.start()
        defer { app.services.cancelBackgroundWork() }

        await Workspace(services: app.services).end(session)
        let request = try #require(try await store.deliveryRequests(toSession: "atlas").last)
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        #expect(app.pi.sessions.isEmpty)
        #expect(first.received == ["end"] && other.received == ["end"])
        #expect(try await store.allPiSessionStates().first?.state == .known(.ended))
    }

    @Test(arguments: ["quit", "reload", "disconnect"])
    func 结束ACK只算受理_只有退出告别才能完成(reason: String) async throws {
        let ext = try await app.host.connect("atlas", cwd: "/")
        ext.onCommand = { _, _ in ["ok": true] }
        let session = try await record()
        try await app.services.executor.start()
        defer { app.services.cancelBackgroundWork() }

        await Workspace(services: app.services).end(session)
        let request = try #require(try await store.deliveryRequests(toSession: "atlas").last)
        try await eventually("结束已交给宿主") { ext.received.contains("end") }
        #expect(try await store.deliveryRequest(request.id)?.isOpen == true)
        #expect(try await store.allPiSessionStates().first?.state != .known(.ended))
        if reason == "disconnect" { ext.crash() } else { ext.close(bye: reason) }

        let result = try await store.outcome(of: request)
        #expect(result.status == (reason == "quit" ? .known(.succeeded) : .known(.unconfirmed)))
        #expect(try await store.allPiSessionStates().first?.state == (reason == "quit" ? .known(.ended) : .known(.settled)))
    }
}

@Suite(.releasesLibraries)
struct SendPrecisionTests {
    private final class Peer: SessionLink {
        var messages: [SessionMessage] = []
        func send(_ message: SessionMessage, in _: Session.ID) async throws { messages.append(message) }
    }

    @Test func 非Pi当前轮经Store往返后允许Cue发话_换轮仍保护() async throws {
        let app = TestApp()
        let started = Date(timeIntervalSince1970: 1_793_290_000.123456)
        var facts = SessionFacts()
        facts.startTurn(at: started)
        var live = Session(
            id: "claude-peer", sessionID: "claude-session", agent: .claudeCode, sessionFile: nil, pid: 0,
            cwd: app.directory, terminal: TerminalIdentity(), state: .settled, stateSince: started)
        live.hosted = true
        facts.publish(to: &live, at: started)
        let peer = Peer()
        app.pi.attach(live, via: peer)
        try await StateRecorder(store: app.services.store, hostID: TestApp.hostID).update(
            sessionID: live.sessionID, state: live.state, title: "Claude", turnStartedAt: live.turnStartedAt, agent: .claudeCode)
        let stored = try #require(try await app.services.store.allPiSessionStates().first?.turnStartedAt)
        #expect(stored != started, "Store 确实把接入的亚毫秒时间按存储合同规范成毫秒")
        let message = SessionMessage(text: "继续自己的任务", policy: .cue(deliveryID: "cue-confirmed", turnStartedAt: stored))

        try await app.pi.send(message, to: live.id)
        #expect(peer.messages.map(\.text) == ["继续自己的任务"])

        facts.startTurn(at: started.addingTimeInterval(0.001))
        app.pi.update(live.id) { facts.publish(to: &$0) }
        await #expect(throws: BridgeError.rejected("user_turn")) { try await app.pi.send(message, to: live.id) }
        #expect(peer.messages.count == 1, "旧许可不能打断新轮")
    }
}

#endif
