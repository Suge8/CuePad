import CueStore
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct AskShotsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func thread() async throws -> CueThread { try await CueThread.read(from: store) }

    private func send(_ names: [String], title: String) async throws -> [PreviewItem] {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try names.map { name in
            let file = folder.appending(path: name)
            try Data(name.utf8).write(to: file)
            return file
        }
        return try await store.addPreviews(files.enumerated().map { (url: $1, title: "\(title) \($0 + 1)") }, sessionID: "s1").map(\.preview)
    }

    @Test func 提问卡与结果卡只带点名的图() async throws {
        let workspace = Workspace(services: app.services)
        let project = try await store.createProject(name: "CuePad", color: "#000000")
        let task = try await store.createTask("重做提问卡", in: project.id)
        try await StateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, projectID: project.id)
        try await store.bindSession("s1", to: task.id)
        _ = try await send(["1-01-改前.png", "1-02-改后.png", "2-01-设置.png"], title: "别的改动")
        let one = try await send(["decision-sheet-iphone.png", "decision-sheet-iphone-dark.png", "decision-sheet-mac.png"], title: "提问卡方案 1：决定单")
        let two = try await send(["in-thread-iphone.png", "in-thread-iphone-dark.png", "in-thread-mac.png"], title: "提问卡方案 2：对话里问")

        let asking = try CueAsking(.rule, action: "按方案 1 决定单改提问卡", rule: "设计方案交回时用 ask rule 让我选")
        let question = try await store.addCueMessage(
            .cue, text: "三个方案做好了，我建议 1。", ask: asking,
            shots: [CueShot(preview: one[0].id, look: "方案 1：大按钮占满一行"), CueShot(preview: two[0].id, look: "方案 2：按钮贴在输入框上")], task: task.id)
        let plain = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送提问卡的改动"), task: task.id)

        let before = try await thread()
        #expect(before.waiting.compactMap(\.message?.id) == [question.id, plain.id])
        #expect(before.shots[question.id]?.map(\.preview.id) == [one[0].id, two[0].id])
        #expect(before.shots[question.id]?.map(\.look) == ["方案 1：大按钮占满一行", "方案 2：按钮贴在输入框上"])
        #expect(before.shots[plain.id] == nil)

        try await workspace.services.answerCueQuestion(question.id, CueAsk.once)
        _ = try await store.addCueMessage(.cue, text: "好，按方案 1 做。", task: task.id)

        let after = try await thread()
        guard let asked = after.rows.first(where: { $0.id == question.id }), case .cue = asked else {
            Issue.record("答完的提问回到对话里是 Cue 的一句：\(after.rows.map(\.id))"); return
        }
        #expect(after.shots[question.id]?.count == 2)
        #expect(!after.rows.contains { if case .result = $0 { true } else { false } } && after.shots.count == 1)

        let final = try await send(["final-light.png", "final-dark.png"], title: "最终版")
        let (report, _) = try await store.finishTask(task.id, evidence: ["按方案 1 改完了"], shots: [CueShot(preview: final[1].id, look: "深色：按钮对比度够")])
        let done = try await thread()
        guard case .result(let card, let id) = done.rows.last(where: { if case .result = $0 { true } else { false } }) else {
            Issue.record("做完那句是结果卡"); return
        }
        #expect(card.id == report?.id && id == task.id && done.shots[card.id]?.map(\.preview.id) == [final[1].id])
        #expect(done.shots[card.id]?.map(\.look) == ["深色：按钮对比度够"])

        func written(_ thread: CueThread) -> [CuePlace?] { thread.messages.filter { $0.taskID == task.id }.map { $0.place(task: task.id) } }
        let frozen = written(done)
        #expect(frozen.allSatisfy { $0?.name == "重做提问卡" } && frozen.last??.status == .known(.done), "\(frozen)")
        try await store.updateCard(task.id) { $0.body = "改了名的任务" }
        _ = try await store.completeTask(task.id)
        #expect(written(try await thread()) == frozen)
    }
}
