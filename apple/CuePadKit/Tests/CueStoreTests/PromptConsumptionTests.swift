import CueStore
import CueTestSupport
import Foundation
import Testing

/// 提示词送达就用掉：发给会话或开新会话的请求写下成功结果的同一刻，带着的提示词从资料库里删掉（不进归档、不进回收站），
/// 任务记下会话，发送记录留着快照；资料与没送到的不删。
@Suite struct PromptConsumptionTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

  /// 与 Mac 执行器一样：发出去后记发送记录，再写回结果。
  private func executor() -> DeliveryExecutor {
    DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { [store] request in
      if request.mode == .known(.send) { _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID) }
      return .succeeded
    }
  }

  private func gone(_ card: Card) async throws {
    _ = try await eventually(store, { try $0.card(card.id) }) { $0 == nil }
  }

  @Test(.timeLimit(.minutes(1))) func 送达就用掉_任务记着会话_发送记录留着快照() async throws {
    let task = try await store.createTask("修乱序", in: nil)
    let sent = try await store.createCard(body: "先复现", under: task.id)
    let waiting = try await store.createCard(body: "再改排序", under: task.id)
    let executor = executor()
    try await executor.start()

    try await store.requestDelivery(sent.body, to: atlas, on: "mac-a", card: sent.id)
    try await gone(sent)
    await executor.stop()

    #expect(try await store.trashedCards().isEmpty)
    #expect(try await store.archived().isEmpty)
    #expect(try await store.children(of: task.id).map(\.id) == [waiting.id])
    #expect(try await store.card(task.id)?.piSessionID == "s1")
    let records = try await store.sendRecords()
    #expect(records.map(\.content) == ["先复现"] && records.first?.cardID == nil)
  }

  @Test(.timeLimit(.minutes(1))) func 资料与没送到的留着() async throws {
    let task = try await store.createTask("修乱序", in: nil)
    let resource = try await store.createCard(body: "常用说明", under: task.id)
    try await store.updateCard(resource.id) { $0.isPinned = true }
    let failing = try await store.createCard(body: "没送到的", under: task.id)
    let waiting = try await store.createCard(body: "还在路上的", under: task.id)

    let failed = try await store.requestDelivery(failing.body, to: atlas, on: "mac-a", card: failing.id)
    let delivered = try await store.requestDelivery(resource.body, to: atlas, on: "mac-a", card: resource.id)
    try await store.requestDelivery(waiting.body, to: atlas, on: "mac-b", card: waiting.id)  // 别的 Mac 的请求，本机不执行
    let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { request in
      request.id == failed.id ? .failed("会话已关闭") : .succeeded
    }
    try await executor.start()
    _ = try await eventually(store, { try $0.deliveryRequests().filter { $0.status != .known(.pending) }.count }) { $0 == 2 }
    await executor.stop()

    #expect(try await store.deliveryRequest(delivered.id)?.status == .known(.succeeded))
    #expect(try await store.children(of: task.id).map(\.id) == [resource.id, failing.id, waiting.id])
  }

  @Test(.timeLimit(.minutes(1))) func 开新会话送达_提示词用掉_会话开好后认领的是任务() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let task = try await store.createTask("修乱序", in: project.id)
    let prompt = try await store.createCard(body: "复现一下", under: task.id)
    let executor = executor()
    try await executor.start()

    try await store.requestLaunch(PiLaunch(project: project.id, prompt: prompt.body, token: "t1"), title: "圆桌", on: "mac-a", card: prompt.id)
    try await gone(prompt)
    await executor.stop()
    #expect(try await store.handedSessions() == [task.id: .launching])

    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s-new", state: .thinking, title: "圆桌", launchToken: "t1")
    let started = try #require(try await store.card(task.id))
    #expect(started.piSessionID == "s-new" && started.status == .inProgress)
  }
}
