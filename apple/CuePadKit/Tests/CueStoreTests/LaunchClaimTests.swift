import CueStore
import Testing

@Suite struct LaunchClaimTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 作废或被后来的交给盖过的开会话请求_不算正在开_开好时也不抢回() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    try await store.setDirectory("/work", for: project.id)
    let bound = try await store.createTask("修乱序", in: project.id), handed = try await store.createTask("改文案", in: project.id)
    for (leaf, token) in [(bound, "t-bound"), (handed, "t-handed")] {  // 同界面的"开新会话"：请求带着叶子自己
      _ = try await store.requestLaunch(LaunchRequest(project: project.id, prompt: nil, token: token), title: "圆桌", on: "mac-a", card: leaf.id)
    }
    #expect(try await store.launchingLeaves([bound.id, handed.id]) == [bound.id, handed.id])

    try await StateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, projectID: project.id)
    try await store.bindSession("s1", to: bound.id)
    try await store.unbindSession(from: bound.id)
    await nextMillisecond()
    _ = try await store.requestDelivery("先看看", to: SendTarget(kind: .piSession, name: "notes", ref: "s2"), on: "mac-a", card: handed.id)
    #expect(try await store.launchingLeaves([bound.id, handed.id]).isEmpty)

    try await StateRecorder(store: store, hostID: "mac-a").update(sessionID: "s-late", state: .thinking, title: "圆桌", launchToken: "t-handed")
    #expect(try await store.card(handed.id)?.piSessionID == nil)
    #expect(try await store.handedSessions()[handed.id] == .session("s2"))
  }

  @Test
  func 会话记录120秒后才到_开新会话的请求留着_仍能关联() async throws {
    let clock = ManualTiming()
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "看一下重连")
    let executor = DeliveryExecutor(
      store: store, hostID: "mac-a", timing: clock.timing, onIssue: { Issue.record("\($0)") }
    ) { _, _ in .succeeded }
    try await executor.start()
    let launch = try await store.requestLaunch(
      LaunchRequest(project: project.id, prompt: idea.body, token: "t-late"), title: "圆桌", on: "mac-a", card: idea.id)
    let plain = try await store.requestDelivery("别的", to: SendTarget(kind: .piSession, name: "notes", ref: "s2"), on: "mac-a", mode: .quota)
    _ = try await eventually(store, { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 2 }

    try await clock.waitForSleeper(until: clock.now.addingTimeInterval(DeliveryExecutor.retention.seconds))
    clock.advance(DeliveryExecutor.retention * 2 + .seconds(1))
    _ = try await eventually(store, { try $0.deliveryRequest(plain.id) }) { $0 == nil }
    #expect(try await store.deliveryRequest(launch.id) != nil)
    #expect(try await store.handedSessions() == [idea.id: .launching(.pi)])

    try await StateRecorder(store: store, hostID: "mac-a").update(sessionID: "s-late", state: .thinking, title: "圆桌", launchToken: "t-late")
    #expect(try await store.card(idea.id)?.piSessionID == "s-late")

    try await clock.waitForSleeper(until: clock.now.addingTimeInterval(DeliveryExecutor.retention.seconds))
    clock.advance(DeliveryExecutor.retention + .seconds(1))
    _ = try await eventually(store, { try $0.deliveryRequest(launch.id) }) { $0 == nil }
    await executor.stop()
  }
}
