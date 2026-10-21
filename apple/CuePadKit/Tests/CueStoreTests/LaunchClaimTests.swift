import CueStore
import CueTestSupport
import Foundation
import Testing

/// 从灵感或任务"新会话"发给 Agent：开会话的请求带着这条灵感或任务，Mac 开好、会话记录带回认领标识（launchToken）时，
/// 它就关联到那个会话（piSessionID），与发给已有会话同一个结果；开好前状态点显示"正在开会话"。
@Suite struct LaunchClaimTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// 正在开会话只认会被认领的那一次：亲手绑定、解绑作废了它，或之后又交给了别的会话，就不再算正在开（Cue 的看板与开工同读这一条）；
  /// 被盖过的那个新会话后来开好，也不把它抢回去（行上的点跟最后一次交给的走）。
  @Test func 作废或被后来的交给盖过的开会话请求_不算正在开_开好时也不抢回() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    try await store.setDirectory("/work", for: project.id)
    let bound = try await store.createTask("修乱序", in: project.id), handed = try await store.createTask("改文案", in: project.id)
    for (leaf, token) in [(bound, "t-bound"), (handed, "t-handed")] {  // 同界面的"开新会话"：请求带着叶子自己
      _ = try await store.requestLaunch(PiLaunch(project: project.id, prompt: nil, token: token), title: "圆桌", on: "mac-a", card: leaf.id)
    }
    #expect(try await store.launchingLeaves([bound.id, handed.id]) == [bound.id, handed.id])

    try await store.bindSession("s1", to: bound.id)
    try await store.unbindSession(from: bound.id)
    try await Task.sleep(for: .milliseconds(5))  // 两次交给落在不同的毫秒（请求按 createdAt 排先后）
    _ = try await store.requestDelivery("先看看", to: SendTarget(kind: .piSession, name: "notes", ref: "s2"), on: "mac-a", card: handed.id)
    #expect(try await store.launchingLeaves([bound.id, handed.id]).isEmpty)

    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s-late", state: .thinking, title: "圆桌", launchToken: "t-handed")
    #expect(try await store.card(handed.id)?.piSessionID == nil)
    #expect(try await store.handedSessions()[handed.id] == .session("s2"))
  }

  /// Mac 上的会话记录晚到（Pi 120 秒后才连上、记下）：开新会话的请求早已完成、过了保留期，
  /// 但它在被认领前不清理，记录到了照样关联；同一轮里别的已完成请求照常清理；认领后下一轮清理带走它。
  @Test(.timeLimit(.minutes(1)))
  func 会话记录120秒后才到_开新会话的请求留着_仍能关联() async throws {
    let clock = ManualTiming()
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "看一下重连")
    let executor = DeliveryExecutor(
      store: store, hostID: "mac-a", timing: clock.timing, onIssue: { Issue.record("\($0)") }
    ) { _ in .succeeded }
    try await executor.start()
    let launch = try await store.requestLaunch(
      PiLaunch(project: project.id, prompt: idea.body, token: "t-late"), title: "圆桌", on: "mac-a", card: idea.id)
    let plain = try await store.requestDelivery("别的", to: SendTarget(kind: .piSession, name: "notes", ref: "s2"), on: "mac-a", mode: .quota)
    _ = try await eventually(store, { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 2 }

    await clock.waitForSleeper()
    clock.advance(DeliveryExecutor.retention * 2 + .seconds(1))
    _ = try await eventually(store, { try $0.deliveryRequest(plain.id) }) { $0 == nil }
    #expect(try await store.deliveryRequest(launch.id) != nil)
    #expect(try await store.handedSessions() == [idea.id: .launching])

    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s-late", state: .thinking, title: "圆桌", launchToken: "t-late")
    #expect(try await store.card(idea.id)?.piSessionID == "s-late")

    await clock.waitForSleeper()
    clock.advance(DeliveryExecutor.retention + .seconds(1))
    _ = try await eventually(store, { try $0.deliveryRequest(launch.id) }) { $0 == nil }
    await executor.stop()
  }
}
