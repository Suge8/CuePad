import CueStore
import Foundation
import Testing
@testable import CuePad

/// 答完的提问在对话里留下你说的一句（Cue 页与会话页同一种：你那一边的气泡，一行引用答的是哪个问题，下面是选的那一项；会话里自己写的答案是全文），
/// 排在答的那一刻。各自只从自己的事实推出：Cue 的是那条提问的 answer / answeredAt，会话的是作答成功时写进对话的那一句。
@MainActor
struct AnswerLineTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func thread() async throws -> CueThread { try await CueThread.read(from: store, showsSteps: true) }

    /// Cue 问了、之后又说了别的，你才答：回答在 Cue 后来那句之后（答的那一刻），引用的是那张卡的问句，点了回到那条提问；
    /// 选第二项的也一样；Cue 撤回的没有这一格；刻度滑条上有你的回答。
    @Test func Cue的提问_答完在答的那一刻留下你的回答() async throws {
        let workspace = Workspace(services: app.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("发言轮次乱序", in: project.id)
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"), task: task.id)
        let delete = try await store.addCueMessage(.cue, text: "要删掉旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"))
        let gone = try await store.addCueMessage(.cue, text: "要发布吗？", ask: try CueAsking(.release, action: "发布 1.4.3"))
        _ = try await store.addCueMessage(.cue, text: "重连用例我也补上了。")

        try await workspace.answerCueQuestion(push, CueAsk.once)
        let always = try #require(delete.choices?.last)
        try await workspace.answerCueQuestion(delete, always)
        _ = try await store.endCueQuestion(gone.id, .withdrawn)

        let thread = try await thread()
        let rows = thread.rows.suffix(3)
        guard case .cue(let later, _) = rows.first, case .answer(let first) = rows.dropFirst().first, case .answer(let second) = rows.last
        else { Issue.record("最后是 Cue 后来那句与你的两条回答：\(thread.rows.map(\.id))"); return }
        #expect(later.text == "重连用例我也补上了。")
        #expect(first.id == push.id && first.answer == CueAsk.once && thread.rows.contains { $0.id == push.id })
        #expect(first.asking?.question == "可以把发言顺序的修复推送到 origin/main 吗？")
        #expect(second.id == delete.id && second.answer == always)
        #expect(!thread.rows.contains { if case .answer(let question) = $0 { question.id == gone.id } else { false } })
        #expect(thread.rows.last?.speaker == .trailing)
        #expect(thread.marks.map(\.preview).suffix(2) == [CueAsk.once, always].map { ChatMark.firstLine($0) })
        // "等你"里不再有它们，计数与摘要照旧只看还开着的提问
        #expect(thread.waiting.isEmpty)
    }

    /// 问得早、对话里已经又说了超过 Cue 页读的那么多句才答：你的回答在最新处，它引用的那条提问也读进来（排在最前），点引用回得去。
    @Test func 早先的提问_答完引用仍回得去() async throws {
        let old = try await store.addCueMessage(.cue, text: "要删掉旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"))
        for index in 0..<CueThread.limit { _ = try await store.addCueMessage(.cue, text: "第 \(index) 句") }
        try await Workspace(services: app.services).answerCueQuestion(old, CueAsk.once)

        let rows = try await thread().rows
        guard case .answer(let question) = rows.last else { Issue.record("最新的是你的回答"); return }
        #expect(question.id == old.id && rows.first?.id == old.id)
    }

    /// 会话里你在 CuePad 答了它的提问：执行作答的 Mac 把你答了什么连同当时的问题写进这个会话的对话，排在答的那一刻
    /// （你的话之后、它接着答完的回答之前；Mac 晚领到也不往后挪）；Cue 替你答的不写。
    @Test func 会话的提问_答完在答的那一刻留下你的回答() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac")
        let question = PiQuestion(promptID: "p-1", kind: .select, text: "要覆盖 public/feed.xml 吗？", options: ["覆盖", "另存为 feed-full.xml"])
        try await recorder.update(sessionID: "s", state: .waitingForUser, title: "homepage", question: question)
        let session = try #require(try await store.allPiSessionStates().first)
        let asked = Date.now
        try await store.writePiTranscript(PiTranscript(
            sessionID: "s", messages: [PiChatMessage(sessionID: "s", entryID: "u1", seq: 1, role: .user, text: "把 RSS 改成全文", at: asked.addingTimeInterval(-60))],
            recap: PiRecap(lastPrompt: "把 RSS 改成全文")))
        let executor = DeliveryExecutor(store: store, hostID: "mac", onIssue: { Issue.record("\($0)") }) { _ in .succeeded }
        defer { Task { await executor.stop() } }

        let request = try await app.services.answer(.option("另存为 feed-full.xml"), to: session)
        _ = try await store.requestAnswer(PiAnswer(promptID: "p-1", value: .option("覆盖"), question: question.text), to: session.target, on: "mac", cue: true)
        // Mac 晚了一阵才领到（离线答的、Mac 睡着）：这期间你在终端里又说了一句；回答仍排在答的那一刻，在这句之前
        try await store.writePiTranscript(PiTranscript(
            sessionID: "s", messages: [PiChatMessage(sessionID: "s", entryID: "u2", seq: 2, role: .user, text: "顺便把 Atom 也输出", at: .now.addingTimeInterval(30))],
            recap: PiRecap(lastPrompt: "顺便把 Atom 也输出")))
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequests().allSatisfy { !$0.isOpen } }) { $0 }
        try await store.writePiTranscript(PiTranscript(
            sessionID: "s",
            messages: [PiChatMessage(sessionID: "s", entryID: "a1", seq: 3, role: .pi, text: "另存好了。", at: .now.addingTimeInterval(60))],
            recap: PiRecap(lastPrompt: "把 RSS 改成全文", lastReply: "另存好了。")))

        let entries = PiChat.entries(try await store.piMessages(of: "s"))
        #expect(entries.map(\.role) == [.user, .answer, .user, .pi])
        #expect(entries[1].text == "另存为 feed-full.xml" && entries[1].question == question.text)
        #expect(try await store.piMessages(of: "s").filter { $0.role == .known(.answer) }.map(\.deliveryID) == [request.id])
        #expect(ChatScrubber.marks(entries).map(\.preview) == ["把 RSS 改成全文", "另存为 feed-full.xml", "顺便把 Atom 也输出"])
    }
}
