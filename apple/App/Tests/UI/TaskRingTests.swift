import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务的完成圈：没有下级是普通圆圈；有下级时圈里画进度——提示词交给 Agent 后那一轮做完（已回复）、子任务完成都算做完，
/// 按做完的比例画（画法是扇形，属外观，以截图验收）。
@MainActor
struct TaskRingTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }
    private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    @Test func 没有下级是普通圆圈() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .plain)
    }

    @Test func 有下级时按已回复与已完成的比例描圈() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        _ = try await store.createCard(body: "再改排序", under: task.id)
        let sub = try await store.createTask("补用例", under: task.id)
        #expect(TaskRing(try await store.childMarks()[task.id]) == .progress(done: 0, total: 3))

        try await store.setStatus(sub.id, .done)
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
        try await Task.sleep(for: .milliseconds(5))  // 会话状态的时刻晚于发出（按毫秒比先后）
        _ = try await recorder.update(sessionID: "s1", state: .thinking, title: "atlas", times: PiTimes(stateSince: .now, busySince: .now))
        #expect(TaskRing(try await store.childMarks()[task.id]) == .progress(done: 1, total: 3))  // 交出去了还没回复：不算
        try await Task.sleep(for: .milliseconds(5))
        _ = try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: .now, busySince: nil))
        #expect(TaskRing(try await store.childMarks()[task.id]) == .progress(done: 2, total: 3))
        #expect(TaskProgress.subtasks(in: try await store.childMarks()[task.id]) == TaskProgress(done: 1, total: 1))
    }
}
