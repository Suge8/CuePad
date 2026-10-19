import CueStore
import Foundation
import Testing
@testable import CuePad

/// 提问卡只带 Cue 点名的那几张图，每张一句看什么（存在提问上，卡片、对话与全屏预览只读它）；关联任务发过的别的交付物不上卡，
/// 照旧挂在 Cue 之后说的话下面（结果卡）。没点名的提问没有图。
@MainActor
struct AskShotsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func thread() async throws -> CueThread { try await CueThread.read(from: store, showsSteps: true) }

    private func send(_ names: [String], title: String) async throws -> [PiPreview] {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try names.map { name in
            let file = folder.appending(path: name)
            try Data(name.utf8).write(to: file)
            return file
        }
        return try await store.addPreviews(filesAt: files, title: title, sessionID: "s1").map(\.preview)
    }

    @Test func 提问卡只带点名的图_答完在对话里还是这几张() async throws {
        let workspace = Workspace(services: app.services)
        let project = try await store.createProject(name: "CuePad", color: "#000000")
        let task = try await store.createTask("重做提问卡", in: project.id)
        try await store.bindSession("s1", to: task.id)
        let earlier = try await send(["1-01-改前.png", "1-02-改后.png", "2-01-设置.png"], title: "别的改动")
        let one = try await send(["decision-sheet-iphone.png", "decision-sheet-iphone-dark.png", "decision-sheet-mac.png"], title: "提问卡方案 1：决定单")
        let two = try await send(["in-thread-iphone.png", "in-thread-iphone-dark.png", "in-thread-mac.png"], title: "提问卡方案 2：对话里问")

        let asking = try CueAsking(
            .rule, action: "按方案 1 决定单改提问卡", rule: "设计方案交回时用 ask rule 让我选",
            shots: [CueShot(preview: one[0].id, look: "方案 1：大按钮占满一行"), CueShot(preview: two[0].id, look: "方案 2：按钮贴在输入框上")])
        let question = try await store.addCueMessage(.cue, text: "三个方案做好了，我建议 1。", ask: asking, task: task.id)
        let plain = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送提问卡的改动"), task: task.id)

        let before = try await thread()
        #expect(before.waiting.map(\.id) == [question.id, plain.id])
        #expect(before.shots[question.id]?.map(\.preview.id) == [one[0].id, two[0].id])
        #expect(before.shots[question.id]?.map(\.look) == ["方案 1：大按钮占满一行", "方案 2：按钮贴在输入框上"])
        #expect(before.shots[plain.id] == nil)

        try await workspace.answerCueQuestion(question, "用 2")
        _ = try await store.addCueMessage(.cue, text: "好，按方案 2 做。", task: task.id)

        let after = try await thread()
        // 提问回到对话里只带它点名的两张；关联任务发过的九份挂在 Cue 之后那句话下面
        guard let asked = after.rows.first(where: { $0.id == question.id }), case .cue = asked else {
            Issue.record("答完的提问回到对话里是 Cue 的一句：\(after.rows.map(\.id))"); return
        }
        #expect(after.shots[question.id]?.count == 2)
        guard case .result(let next, _, let deliverables) = after.rows.first(where: { if case .result = $0 { true } else { false } }) else {
            Issue.record("Cue 之后那句是结果卡"); return
        }
        #expect(next.text == "好，按方案 2 做。" && Set(deliverables.map(\.id)) == Set((earlier + one + two).map(\.id)))
    }
}
