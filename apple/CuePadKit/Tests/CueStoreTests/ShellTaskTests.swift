@testable import CueStore
import CueTestSupport
import Foundation
import Testing

/// 外壳：不经任务、直接开的会话由 Mac 自动建的同名任务。它只是会话的投影——会话正常结束它就完成并归档，被打断、出错照旧留着，
/// 会话又活过来它回到进行中；有人动过它（改标题、写提示词、加步骤、挪项目、完成），它就是普通任务，不再跟着会话收尾。
@Suite struct ShellTaskTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  let host = "mac-a"
  var recorder: PiStateRecorder { PiStateRecorder(store: store, hostID: host) }

  /// 终端里开了个会话、在干活：Mac 给它建了外壳。
  private func openShell() async throws -> Card {
    try await store.ownSessions(host: host)
    try await recorder.update(sessionID: "s1", state: .thinking, title: "修登录")
    let shell = try #require(try await store.card(CueStore.sessionTaskID("s1")))
    #expect(shell.status == .inProgress && shell.archivedAt == nil)
    return shell
  }

  private func shell(_ id: UUID) async throws -> Card { try #require(try await store.card(id)) }

  @Test func 会话正常结束_外壳完成并归档() async throws {
    let shell = try await openShell()
    try await recorder.update(sessionID: "s1", state: .settled)
    try await recorder.end(sessionID: "s1")

    let closed = try await self.shell(shell.id)
    #expect(closed.status == .done && closed.archivedAt != nil)
  }

  enum Stop: String, CaseIterable { case interrupted, failed }

  @Test(arguments: Stop.allCases) func 会话被打断或出错_外壳留着_原因看会话状态(_ stop: Stop) async throws {
    let shell = try await openShell()
    switch stop {
    case .interrupted: try await recorder.exited(sessionID: "s1", spoke: true)  // 干活时进程没了
    case .failed: try await recorder.update(sessionID: "s1", state: .error, detail: "额度用完了")
    }

    let kept = try await self.shell(shell.id)
    #expect(kept.status == .inProgress && kept.archivedAt == nil)
    let state = try #require(try await store.allPiSessionStates().first { $0.sessionID == "s1" })
    #expect(state.state == (stop == .interrupted ? .known(.interrupted) : .known(.error)))
  }

  enum Touch: String, CaseIterable { case title, prompt, step, project, done }

  @Test(arguments: Touch.allCases) func 外壳被动过就是普通任务_会话结束不跟着收尾(_ touch: Touch) async throws {
    let shell = try await openShell()
    switch touch {
    case .title: try await store.updateCard(shell.id) { $0.body = "修登录跳转" }
    case .prompt: _ = try await store.createCard(body: "先看日志", under: shell.id)
    case .step: _ = try await store.createTask("复现", under: shell.id)
    case .project:
      let project = try await store.createProject(name: "圆桌", color: "#111")
      _ = try await store.moveCard(shell.id, to: .top(project: project.id), after: nil)
    case .done: _ = try await store.finishTask(shell.id, evidence: ["- 登录修好了"])  // Cue 派 done
    }
    try await recorder.update(sessionID: "s1", state: .settled)
    try await recorder.end(sessionID: "s1")

    let kept = try await self.shell(shell.id)
    #expect(kept.archivedAt == nil)
    #expect(kept.status == (touch == .done ? .done : .inProgress))
  }

  @Test func 跟着结束归档的外壳_会话恢复后回到进行中() async throws {
    let shell = try await openShell()
    try await recorder.update(sessionID: "s1", state: .settled)
    try await recorder.end(sessionID: "s1")
    #expect(try await self.shell(shell.id).archivedAt != nil)

    try await recorder.update(sessionID: "s1", state: .thinking)  // 给已结束的会话发话：Mac 在后台恢复它
    let revived = try await self.shell(shell.id)
    #expect(revived.status == .inProgress && revived.archivedAt == nil)
  }
}
