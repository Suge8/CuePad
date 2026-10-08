import CueStore
import CueTestSupport
import Foundation
import Testing

/// 从灵感或任务"新会话"交给 Agent：开会话的请求带着这条灵感或任务，Mac 开好、会话记录带回认领标识（launchToken）时，
/// 它就关联到那个会话（piSessionID），与发给已有会话同一个结果；开好前状态点显示"正在开会话"。
@Suite struct LaunchClaimTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 开会话前是正在开会话_Mac开好写回会话记录后关联到那个会话() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "看一下重连")
    let task = try await store.createTask("修乱序", in: project.id)
    _ = try await store.requestLaunch(PiLaunch(place: .project(project.id), prompt: idea.body, token: "t-idea"), title: "圆桌", on: "mac-a", card: idea.id)
    _ = try await store.requestLaunch(PiLaunch(place: .project(project.id), prompt: "修乱序", token: "t-task"), title: "圆桌", on: "mac-a", card: task.id)

    #expect(try await store.handedSessions() == [idea.id: .launching, task.id: .launching])

    // Mac 上开好的会话按认领标识记下（本机记录器与同步过来的记录走同一处认领）
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    try await recorder.update(sessionID: "s-idea", state: .thinking, title: "圆桌", launchToken: "t-idea")
    try await recorder.update(sessionID: "s-task", state: .thinking, title: "圆桌", launchToken: "t-task")

    #expect(try await store.card(idea.id)?.piSessionID == "s-idea")
    let started = try #require(try await store.card(task.id))
    #expect(started.piSessionID == "s-task" && started.status == .inProgress)
    #expect(try await store.handedSessions() == [idea.id: .session("s-idea"), task.id: .session("s-task")])
  }

  /// 开新会话后又把它交给了别的会话：以后一次为准，新会话开好时不把它抢回去（行上的点跟最后一次交给的走）。
  @Test func 之后又交给了别的会话_新会话开好时不抢回() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "看一下重连")
    _ = try await store.requestLaunch(PiLaunch(place: .project(project.id), prompt: idea.body, token: "t-old"), title: "圆桌", on: "mac-a", card: idea.id)
    try await Task.sleep(for: .milliseconds(5))  // 两次交给落在不同的毫秒（请求按 createdAt 排先后）
    _ = try await store.requestDelivery(idea.body, to: SendTarget(kind: .piSession, name: "notes", ref: "s2"), on: "mac-a", card: idea.id)

    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s-old", state: .thinking, title: "圆桌", launchToken: "t-old")

    #expect(try await store.card(idea.id)?.piSessionID == nil)
    #expect(try await store.handedSessions() == [idea.id: .session("s2")])
  }
}
