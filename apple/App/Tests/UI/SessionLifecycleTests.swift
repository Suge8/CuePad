#if os(macOS)
@testable import CueBridge
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
        return try #require(try await store.allSessionStates().first)
    }

    @Test func 结束同一会话的所有宿主_不按名字或目录隐藏外部RPC() async throws {
        let first = try await app.host.connect("atlas", cwd: "/")
        let other = FakeExtension(
            directory: app.socketDirectory, sessionID: "atlas", pid: Int32.max - 1,
            options: .init(cwd: "/"))
        other.onCommand = { [weak other] _, command in
            if command["t"] as? String == "end" { other?.closeAfterReply(bye: "quit") }
            return ["ok": true]
        }
        try other.start()
        defer { other.crash() }
        try await eventually("两个宿主都可见") { app.bridge.sessions.count == 2 }
        let session = try await record()
        try await app.services.executor.start()

        await Workspace(services: app.services).end(session)
        let request = try #require(try await store.deliveryRequests(toSession: "atlas").last)
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        #expect(app.bridge.sessions.isEmpty)
        #expect(first.received == ["end"] && other.received == ["end"])
        #expect(try await store.allSessionStates().first?.state == .known(.ended))
    }

    @Test(arguments: ["quit", "reload", "disconnect"])
    func 结束ACK只算受理_只有退出告别才能完成(reason: String) async throws {
        let ext = try await app.host.connect("atlas", cwd: "/")
        ext.onCommand = { _, _ in ["ok": true] }
        let session = try await record()
        try await app.services.executor.start()

        await Workspace(services: app.services).end(session)
        let request = try #require(try await store.deliveryRequests(toSession: "atlas").last)
        try await eventually("结束已交给宿主") { ext.received.contains("end") }
        #expect(try await store.deliveryRequest(request.id)?.isOpen == true)
        #expect(try await store.allSessionStates().first?.state != .known(.ended))
        if reason == "disconnect" { ext.crash() } else { ext.close(bye: reason) }

        let result = try await store.outcome(of: request)
        #expect(result.status == (reason == "quit" ? .known(.succeeded) : .known(.unconfirmed)))
        #expect(try await store.allSessionStates().first?.state == (reason == "quit" ? .known(.ended) : .known(.settled)))
    }
}

@Suite(.releasesLibraries)
struct CueSendGuardTests {
    private final class Peer: SessionLink {
        var messages: [SessionMessage] = []
        func send(_ message: SessionMessage, in _: Session.ID) async throws { messages.append(message) }
    }

    @Test func Cue的话只插进Cue开的那一轮() async throws {
        let app = TestApp()
        let live = Session(
            id: "claude-peer", sessionID: "claude-session", agent: .claudeCode, sessionFile: nil, pid: 0, cwd: app.directory, state: .thinking, stateSince: .now)
        let peer = Peer()
        app.bridge.attach(live, via: peer)
        let cue = SessionMessage(text: "顺便跑一遍 lint", deliveryID: UUID().uuidString, policy: .cue)
        func opened(cue: Bool) { app.bridge.update(live.id) { $0.turnOpener = TurnOpener(delivery: UUID(), cue: cue) } }

        await #expect(throws: BridgeError.rejected("unconfirmed_turn")) { try await app.bridge.send(cue, to: live.id) }
        opened(cue: false)
        await #expect(throws: BridgeError.rejected("user_turn")) { try await app.bridge.send(cue, to: live.id) }
        opened(cue: true)
        try await app.bridge.send(cue, to: live.id)
        #expect(peer.messages.map(\.text) == ["顺便跑一遍 lint"])
    }
}

#endif
