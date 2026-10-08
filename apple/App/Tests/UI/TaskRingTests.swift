import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务以完成圈为主角：每条提示词、每个子任务各占一段——提示词交给 Agent 后那一轮做完（已回复）、子任务完成那一段就满；
/// 没有下级是普通圆圈；太多时按比例画。
@MainActor
struct TaskRingTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }
    private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    @Test func 没有下级是普通圆圈() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .plain)
    }

    @Test func 每条提示词与子任务各占一段_已回复或完成那段就满() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        _ = try await store.createCard(body: "再改排序", under: task.id)
        let sub = try await store.createTask("补用例", under: task.id)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .segments([false, false, false]))

        try await store.setStatus(sub.id, .done)
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
        _ = try await recorder.update(sessionID: "s1", state: .thinking, title: "atlas")
        #expect(TaskRing(try await store.childMarks()[task.id]) == .segments([false, false, true]))  // 交出去了还没回复：不满
        try await Task.sleep(for: .milliseconds(5))
        _ = try await recorder.update(sessionID: "s1", state: .settled)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .segments([true, false, true]))
        #expect(TaskProgress.subtasks(in: try await store.childMarks()[task.id]) == TaskProgress(done: 1, total: 1))
    }

    @Test func 下级超过上限时按比例画() async throws {
        let task = try await store.createTask("大任务", in: nil)
        for index in 0..<(TaskRing.maxSegments + 3) {
            let sub = try await store.createTask("第 \(index) 步", under: task.id)
            if index < 5 { try await store.setStatus(sub.id, .done) }
        }
        #expect(TaskRing(try await store.childMarks()[task.id]) == .fraction(done: 5, total: TaskRing.maxSegments + 3))
    }
}
