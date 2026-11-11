import CueStore
import Foundation
import Testing
@testable import CuePad

/// 各自只从自己的事实推出：Cue 的是那条提问的 answer / answeredAt，会话的是作答成功时写进对话的那一句。
@MainActor
@Suite(.releasesLibraries)
struct AnswerLineTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func thread() async throws -> CueThread { try await CueThread.read(from: store) }

    @Test func Cue的提问_答完在答的那一刻留下你的回答() async throws {
        let workspace = Workspace(services: app.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("发言轮次乱序", in: project.id)
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"), task: task.id)
        let delete = try await store.addCueMessage(.cue, text: "要删掉旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"))
        let gone = try await store.addCueMessage(.cue, text: "要发布吗？", ask: try CueAsking(.release, action: "发布 1.4.3"))
        for index in 0..<CueThread.limit { _ = try await store.addCueMessage(.cue, text: "第 \(index) 句") }
        _ = try await store.addCueMessage(.cue, text: "重连用例我也补上了。")

        try await workspace.services.answerCueQuestion(push.id, CueAsk.once)
        let always = try #require(delete.choices?.last)
        try await workspace.services.answerCueQuestion(delete.id, always)
        _ = try await store.endCueQuestion(gone.id, .withdrawn)

        let thread = try await thread()
        let rows = thread.rows.suffix(3)
        guard case .cue(let later, _) = rows.first, case .answer(let first, quoted: true) = rows.dropFirst().first, case .answer(let second, quoted: true) = rows.last
        else { Issue.record("最后是 Cue 后来那句与你的两条回答：\(thread.rows.map(\.id))"); return }
        #expect(later.text == "重连用例我也补上了。")
        #expect(first.id == push.id && first.answer == CueAsk.once && thread.rows.prefix(2).map(\.id) == [push.id, delete.id])
        #expect(first.asking?.question == "可以把发言顺序的修复推送到 origin/main 吗？")
        #expect(second.id == delete.id && second.answer == always)
        #expect(!thread.rows.contains { if case .answer(let question, _) = $0 { question.id == gone.id } else { false } })
        #expect(thread.rows.last?.speaker == .trailing)
        #expect(thread.marks.map(\.preview).suffix(2) == [CueAsk.once, always].map { ChatMark.firstLine($0) })
        #expect(thread.waiting.isEmpty)
    }

    @Test func 会话的提问_答完在答的那一刻留下你的回答() async throws {
        let recorder = StateRecorder(store: store, hostID: "mac")
        let question = Question(promptID: "p-1", kind: .select, text: "要覆盖 public/feed.xml 吗？", options: ["覆盖", "另存为 feed-full.xml"])
        try await recorder.update(sessionID: "s", state: .waitingForUser, title: "homepage", question: question)
        let session = try #require(try await store.allPiSessionStates().first)
        let asked = Date.now
        try await store.writePiTranscript(SessionTranscript(
            sessionID: "s", messages: [ChatMessage(sessionID: "s", entryID: "u1", seq: 1, role: .user, text: "把 RSS 改成全文", at: asked.addingTimeInterval(-60))],
            recap: Recap(lastPrompt: "把 RSS 改成全文")))
        let executor = DeliveryExecutor(store: store, hostID: "mac", onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
        defer { await executor.stop() }

        let request = try await app.services.answer(.option("另存为 feed-full.xml"), to: session)
        _ = try await store.requestAnswer(Answer(promptID: "p-1", value: .option("覆盖"), question: question.text), to: session.target, on: "mac", cue: true)
        // Mac 晚了一阵才领到（离线答的、Mac 睡着）：这期间你在终端里又说了一句；回答仍排在答的那一刻，在这句之前
        try await store.writePiTranscript(SessionTranscript(
            sessionID: "s", messages: [ChatMessage(sessionID: "s", entryID: "u2", seq: 2, role: .user, text: "顺便把 Atom 也输出", at: .now.addingTimeInterval(30))],
            recap: Recap(lastPrompt: "顺便把 Atom 也输出")))
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequests().allSatisfy { !$0.isOpen } }) { $0 }
        try await store.writePiTranscript(SessionTranscript(
            sessionID: "s",
            messages: [ChatMessage(sessionID: "s", entryID: "a1", seq: 3, role: .pi, text: "另存好了。", at: .now.addingTimeInterval(60))],
            recap: Recap(lastPrompt: "把 RSS 改成全文", lastReply: "另存好了。")))

        let entries = Chat.entries(try await store.piMessages(of: "s"))
        #expect(entries.map(\.role) == [.user, .answer, .user, .pi])
        #expect(entries[1].text == "另存为 feed-full.xml" && entries[1].question == question.text)
        #expect(try await store.piMessages(of: "s").filter { $0.role == .known(.answer) }.map(\.deliveryID) == [request.id])
        #expect(ChatScrubber.marks(entries).map(\.preview) == ["把 RSS 改成全文", "另存为 feed-full.xml", "顺便把 Atom 也输出"])
    }
}
