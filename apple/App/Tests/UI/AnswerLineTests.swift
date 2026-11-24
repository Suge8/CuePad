import CueStore
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct AnswerLineTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func thread() async throws -> CueThread { try await CueThread.read(from: store) }

    @Test func 会话的提问_答完在答的那一刻留下你的回答() async throws {
        let recorder = StateRecorder(store: store, hostID: "mac")
        let question = Question(promptID: "p-1", kind: .select, text: "要覆盖 public/feed.xml 吗？", options: ["覆盖", "另存为 feed-full.xml"])
        try await recorder.update(sessionID: "s", state: .waitingForUser, title: "homepage", question: question)
        let session = try #require(try await store.allSessionStates().first)
        let asked = Date.now
        try await store.writeTranscript(SessionTranscript(
            sessionID: "s", messages: [ChatMessage(sessionID: "s", entryID: "u1", seq: 1, role: .user, text: "把 RSS 改成全文", at: asked.addingTimeInterval(-60))],
            recap: Recap(lastPrompt: "把 RSS 改成全文")))
        let executor = DeliveryExecutor(store: store, hostID: "mac", onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
        defer { await executor.stop() }

        let request = try await app.services.answer(.option("另存为 feed-full.xml"), to: session)
        _ = try await store.requestAnswer(Answer(promptID: "p-1", value: .option("覆盖"), question: question.text), to: session.target, on: "mac", cue: true)
        try await store.writeTranscript(SessionTranscript(
            sessionID: "s", messages: [ChatMessage(sessionID: "s", entryID: "u2", seq: 2, role: .user, text: "顺便把 Atom 也输出", at: .now.addingTimeInterval(30))],
            recap: Recap(lastPrompt: "顺便把 Atom 也输出")))
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequests().allSatisfy { !$0.isOpen } }) { $0 }
        try await store.writeTranscript(SessionTranscript(
            sessionID: "s",
            messages: [ChatMessage(sessionID: "s", entryID: "a1", seq: 3, role: .pi, text: "另存好了。", at: .now.addingTimeInterval(60))],
            recap: Recap(lastPrompt: "把 RSS 改成全文", lastReply: "另存好了。")))

        let entries = Chat.entries(try await store.chatMessages(of: "s"))
        #expect(entries.map(\.role) == [.user, .answer, .user, .pi])
        #expect(entries[1].text == "另存为 feed-full.xml" && entries[1].question == question.text)
        #expect(try await store.chatMessages(of: "s").filter { $0.role == .known(.answer) }.map(\.deliveryID) == [request.id])
    }
}
