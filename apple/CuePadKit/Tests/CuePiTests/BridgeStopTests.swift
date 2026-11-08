#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

@MainActor
struct BridgeStopTests {
    final class RecordingLink: SessionLink {
        var messages: [String] = []
        var reply: CheckedContinuation<Void, any Error>?
        var hold = false

        func send(_ message: PiMessage, in id: PiSession.ID) async throws {
            messages.append(message.text)
            if hold { try await withCheckedThrowingContinuation { reply = $0 } }
        }
    }

    @Test func stopCancelsQueuedMessagesBeforeAttachingTheSameSession() async throws {
        let directory = try makeTempDirectory()
        let ext = FakeExtension(directory: directory)
        ext.onCommand = { _, _ in nil }
        try ext.start()
        let bridge = PiBridge(socketDirectory: directory)
        defer { bridge.stop(); ext.crash() }
        try bridge.start()
        try await eventually("socket connected") { bridge.session(id: ext.id) != nil }
        let snapshot = try #require(bridge.session(id: ext.id))
        let first = Task { try await bridge.send(PiMessage(text: "first"), to: ext.id) }
        try await eventually("first awaiting ACK") { ext.commands.contains { $0.json["text"] as? String == "first" } }
        var entered = false
        let queued = Task {
            entered = true
            try await bridge.send(PiMessage(text: "queued-old"), to: ext.id)
        }
        try await eventually("second queued") { entered }
        let next = RecordingLink()
        bridge.stop()
        bridge.attach(snapshot, via: next)
        await #expect(throws: PiBridgeError.sessionEnded) { try await first.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(next.messages.isEmpty)
        try await bridge.send(PiMessage(text: "new"), to: ext.id)
        #expect(next.messages == ["new"])
        #expect(!ext.commands.contains { $0.json["t"] as? String == "end" })
    }

    @Test func stopRevokesAReleasedQueuePermitBeforeItsBodyRuns() async throws {
        let directory = try makeTempDirectory()
        let bridge = PiBridge(socketDirectory: directory)
        defer { bridge.stop() }
        let session = PiSession(
            id: "session.1", sessionID: "session", agent: .pi, sessionFile: nil, pid: 1,
            cwd: directory, terminal: PiTerminal(), state: .settled, stateSince: .now)
        let old = RecordingLink(), next = RecordingLink()
        old.hold = true
        bridge.attach(session, via: old)
        let first = Task {
            try await bridge.send(PiMessage(text: "first"), to: session.id)
            // send 的 defer 已将许可交给队首；同一主线程任务里 stop 先于队首恢复。
            bridge.stop()
            bridge.attach(session, via: next)
        }
        try await eventually("first handed off") { old.reply != nil }
        var entered = false
        let queued = Task {
            entered = true
            try await bridge.send(PiMessage(text: "released-old"), to: session.id)
        }
        try await eventually("second queued") { entered }
        old.reply?.resume()
        try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(old.messages == ["first"])
        #expect(next.messages.isEmpty)
        try await bridge.send(PiMessage(text: "new"), to: session.id)
        #expect(next.messages == ["new"])
    }

    @Test func stopKeepsTheHandedOffResultAndSerializesNewMessages() async throws {
        let directory = try makeTempDirectory()
        let bridge = PiBridge(socketDirectory: directory)
        defer { bridge.stop() }
        let session = PiSession(
            id: "session.1", sessionID: "session", agent: .pi, sessionFile: nil, pid: 1,
            cwd: directory, terminal: PiTerminal(), state: .settled, stateSince: .now)
        let old = RecordingLink(), next = RecordingLink()
        old.hold = true
        bridge.attach(session, via: old)
        let first = Task { try await bridge.send(PiMessage(text: "handed-off"), to: session.id) }
        try await eventually("old message handed off") { old.reply != nil }
        bridge.stop()
        bridge.attach(session, via: next)
        var entered = false
        let newFirst = Task {
            entered = true
            try await bridge.send(PiMessage(text: "new-first"), to: session.id)
        }
        try await eventually("new first entered") { entered }
        entered = false
        let newSecond = Task {
            entered = true
            try await bridge.send(PiMessage(text: "new-second"), to: session.id)
        }
        try await eventually("new second entered") { entered }
        #expect(next.messages.isEmpty)
        old.reply?.resume(throwing: PiBridgeError.rejected("delivery-failed"))
        await #expect(throws: PiBridgeError.rejected("delivery-failed")) { try await first.value }
        try await newFirst.value
        try await newSecond.value
        #expect(next.messages == ["new-first", "new-second"])
    }

}
#endif
