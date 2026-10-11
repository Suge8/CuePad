@testable import CueStore
import Foundation
import Testing

extension CueStore {
  fileprivate func tablesRead(_ read: @Sendable (isolated CueStore) throws -> some Any) throws -> Set<Table> {
    try db.tracking { try read(self) }.reads
  }
}

/// 订阅的依赖由读取实际读到的表定（`observe(_:)`），不靠调用处另写一份表名。
@Suite struct ReadTrackingTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// 提示词"已回复"取决于会话状态：会话歇下后，只读了任务下级进度的订阅也要重读。
  @Test(.timeLimit(.minutes(1))) func 订阅随读取走_会话歇下后子任务进度立即更新() async throws {
    let task = try await store.createTask("修乱序", in: nil)
    let prompt = try await store.createCard(body: "先复现", under: task.id)
    let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
    try await recorder.update(sessionID: "s1", state: .thinking, title: "atlas")
    var marks = store.observe { try $0.childMarks(of: task.id)[task.id]?.map(\.isDone) ?? [] }.makeAsyncIterator()
    #expect(try await marks.next() == [false])

    try await Task.sleep(for: .milliseconds(5))
    try await recorder.update(sessionID: "s1", state: .settled, title: "atlas", times: PiTimes(stateSince: .now, busySince: nil))
    #expect(try await marks.next() == [true])
  }
}
