#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

@Suite(.releasesLibraries)
struct ConversationSafetyTests {
    @Test func Cue不打断来源未确认的运行轮次() async throws {
        let app = TestApp(), store = app.services.store
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let task = try await workspace.createTask("来源未确认", in: Project.defaultID)
        let session = UUID().uuidString.lowercased()
        _ = try await store.recordMacPresence(host: TestApp.hostID) { true }
        try await StateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: session, state: .thinking)
        try await store.bindSession(session, to: task.id)
        let delivery = UUID(), at = Date.now
        try await store.writePiTranscript(SessionTranscript(
            sessionID: session,
            messages: [ChatMessage(
                sessionID: session, entryID: "unknown-origin", seq: 1, role: .user, text: "已经收到，但来源记录尚未到达",
                at: at, deliveryID: delivery)],
            recap: Recap(pendingPrompt: "已经收到，但来源记录尚未到达")))
        let host = TestApp.hostID
        try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = at }
        let cue = CueTools(store: store)

        let result = try #require(await cue.call("task", [
            "action": "say", "task": task.id.uuidString, "text": "不要打断未确认的一轮"
        ]))

        #expect(result.isError)
        #expect(result.text.contains("查不到是谁开的"))
        #expect(!result.text.contains("他发起的一轮"))
        #expect(try await store.deliveryRequests().isEmpty)
        #expect(try await store.piMessages(of: session).map(\.text) == ["已经收到，但来源记录尚未到达"])
    }
}
#endif
