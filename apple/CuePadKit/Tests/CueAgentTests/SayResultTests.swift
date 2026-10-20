import CueAgent
import CueStore
import CueTestSupport
import Foundation
import Testing

/// Cue 对会话说话（say）等送达结果再返回，结果按说的话那条规则（`Speech`）读：已送达；没送到时标成出错、带 Mac 给的原因；
/// 到点还没结果就如实说还没送达。执行它的 Mac 由执行器替身扮演。
@Suite struct SayResultTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// Cue 跟进的一件事，绑着 mac-a 上正在跑一轮的会话。
  private func task() async throws -> Card {
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("修好登录页")
    try await store.linkCard(task.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .thinking, title: "修好登录页")
    return task
  }

  private func say(_ task: Card, with tools: CueTools) async throws -> CueTools.Result {
    try #require(await tools.call("task", ["action": "say", "task": task.id.uuidString, "text": "先跑测试"]))
  }

  private func mac(_ outcome: DeliveryOutcome) async throws -> DeliveryExecutor {
    let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _ in outcome }
    try await executor.start()
    return executor
  }

  @Test(.timeLimit(.minutes(1))) func 送到了_说已送达() async throws {
    let task = try await task()
    let mac = try await mac(.succeeded)
    let result = try await say(task, with: CueTools(store: store))
    await mac.stop()
    #expect(!result.isError && result.text.contains("已送达"), "\(result.text)")
  }

  @Test(.timeLimit(.minutes(1))) func 没送到_标成出错并带上Mac给的原因() async throws {
    let task = try await task()
    let mac = try await mac(.failed("这个会话正开在别处（如终端里）"))
    let result = try await say(task, with: CueTools(store: store))
    await mac.stop()
    #expect(result.isError && result.text.contains("没送到") && result.text.contains("这个会话正开在别处"), "\(result.text)")
  }

  @Test(.timeLimit(.minutes(1))) func 到点还没结果_如实说还没送达() async throws {
    let task = try await task()
    let result = try await say(task, with: CueTools(store: store, wait: 0.3))
    #expect(!result.isError && result.text.contains("已发出，还没送达"), "\(result.text)")
    #expect(try await store.deliveryRequests(toSession: "s1").map(\.status) == [.known(.pending)])
  }
}
