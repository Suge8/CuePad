import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务以完成圈为主角：每个子任务、每条挂着的灵感各占一段——子任务完成、灵感交给过 Agent（它自己的发送记录，
/// 或某次发送明确记着带上了它）那一段就满；没有下级是普通圆圈；太多时按比例画。交给 Agent 时可一并带上挂着的灵感与本项目资料。
@MainActor
struct TaskRingTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }
    private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    @Test func 没有下级是普通圆圈() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .plain)
    }

    @Test func 每个子任务与灵感各占一段_子任务完成或灵感交给过Agent那段就满() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let sub = try await store.createTask("复现", under: task.id)
        _ = try await store.createTask("改排序", under: task.id)
        let log = try await workspaceAttach("日志在 logs/0918.txt", to: task)
        let note = try await workspaceAttach("第 6 位重连后排到最前", to: task)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .segments([false, false, false, false]))

        try await store.setStatus(sub.id, .done)
        try await store.recordSend(log.body, to: atlas, card: log.id)
        // 任务连同 note 一起发出：这次发送记着带上了 note，它那一段也满
        try await store.recordSend(TaskBundle.text(task: "修乱序", parts: [note]), to: atlas, card: task.id, parts: [note.id])
        #expect(TaskRing(try await store.childMarks()[task.id]) == .segments([true, false, true, true]))
        #expect(TaskProgress.subtasks(in: try await store.childMarks()[task.id]) == TaskProgress(done: 1, total: 2))
    }

    @Test func 带变量的灵感一起发出后那段填满_只看发送记下的关联不看正文像不像() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let branch = try await workspaceAttach("审查 {{分支}} 的改动\n---split---\n只报错误行为", to: task)
        try await store.updateCard(branch.id) { $0.variableValues = ["分支": "fix/queue"] }
        let quoted = try await workspaceAttach("日志在 logs/0918.txt", to: task)
        let filled = try #require(try await store.card(branch.id))

        // 正文里恰好引了 quoted 的原文，但这次没带上它：不算交给过
        let text = TaskBundle.text(task: "修乱序\n\n参考：日志在 logs/0918.txt", parts: [filled])
        try await store.recordSend(text, to: atlas, card: task.id, parts: [filled.id])

        #expect(TaskRing(try await store.childMarks()[task.id]) == .segments([true, false]))
        _ = quoted
    }

    @Test func 手机发到Mac的请求记着带上的灵感_Mac执行后那段填满() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let note = try await workspaceAttach("第 6 位重连后排到最前", to: task)
        let request = try await store.requestDelivery("修乱序", to: atlas, on: "mac-a", card: task.id, parts: [note.id])
        #expect(try await store.deliveryRequest(request.id)?.partIDs == [note.id])

        try await store.recordSend(request.content, to: request.target, card: request.cardID, parts: request.partIDs)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .segments([true]))
    }

    @Test func 下级超过上限时按比例画() async throws {
        let task = try await store.createTask("大任务", in: nil)
        for index in 0..<(TaskRing.maxSegments + 3) {
            let sub = try await store.createTask("第 \(index) 步", under: task.id)
            if index < 5 { try await store.setStatus(sub.id, .done) }
        }
        #expect(TaskRing(try await store.childMarks()[task.id]) == .fraction(done: 5, total: TaskRing.maxSegments + 3))
    }

    @Test func 交给Agent的正文是任务加上选中的灵感_用分隔线隔开() async throws {
        let first = try await store.createCard(in: nil, body: "日志\n\nlogs/0918.txt")
        let second = try await store.createCard(in: nil, body: "猜测：重连拿了新时间戳")
        #expect(TaskBundle.text(task: "修乱序\n\n先别改代码", parts: [first, second])
            == "修乱序\n\n先别改代码\n\n---\n\n日志\n\nlogs/0918.txt\n\n---\n\n猜测：重连拿了新时间戳")
        #expect(TaskBundle.text(task: "修乱序", parts: []) == "修乱序")
    }

    @Test func 任务浮窗读到挂着的灵感与本项目资料() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("修乱序", in: project.id)
        let material = try await workspaceAttach("日志", to: task)
        let reference = try await store.createCard(in: project.id, body: "接口约定")
        try await store.updateCard(reference.id) { $0.isPinned = true }
        _ = try await store.createCard(in: project.id, body: "随手一条")

        let detail = try await TaskDetail.read(task.id, from: store)
        #expect(detail.materials.map(\.id) == [material.id])
        #expect(detail.resources.map(\.id) == [reference.id])
    }

    @Test func 在任务下记一条灵感_直接挂成它的素材() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("修乱序", in: project.id)
        let workspace = Workspace(services: rig.services)

        try await CaptureDraft(text: "  日志在 logs  ", images: []).save(in: project.id, under: task.id, workspace: workspace)

        let children = try await store.children(of: task.id)
        #expect(children.map(\.body) == ["日志在 logs"])
        #expect(children.first?.isTask == false && children.first?.projectID == project.id)
        #expect(workspace.notice?.undo != nil)
    }

    private func workspaceAttach(_ body: String, to task: Card) async throws -> Card {
        let idea = try await store.createCard(in: task.projectID, body: body)
        try await Workspace(services: rig.services).attach(idea.id, to: task.id)
        return try #require(try await store.card(idea.id))
    }
}
