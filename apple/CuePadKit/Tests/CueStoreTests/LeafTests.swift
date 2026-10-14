import CueStore
import CueTestSupport
import Foundation
import Testing

/// 任务 → 步骤 → 会话：叶子（没有步骤的任务）才有草稿与会话，一个会话只绑一个叶子。
@Suite struct LeafTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 加第一个步骤时_叶子的草稿与会话移到这个步骤上() async throws {
    let task = try await store.createTask("修乱序", in: nil)
    let draft = try await store.createCard(body: "跑一下测试", under: task.id)
    try await store.linkCard(task.id, toSession: "s1")

    let step = try await store.createTask("复现", under: task.id)
    #expect(try await store.children(of: step.id).map(\.id) == [draft.id])
    #expect(step.piSessionID == "s1" && step.startedAt != nil)
    let upper = try #require(try await store.card(task.id))
    #expect(upper.piSessionID == nil)

    // 再加一个步骤不动：草稿与会话已经在第一个步骤上
    _ = try await store.createTask("改排序", under: task.id)
    #expect(try await store.children(of: step.id).map(\.id) == [draft.id])
  }

  @Test func 对叶子的会话说话_方式按会话此刻的状态定_开工时草稿等它做完再交() async throws {
    let leaf = try await store.createTask("修乱序", in: nil)
    await #expect(throws: CueStoreError.noSession("修乱序")) { try await store.sayToLeaf(leaf.id, text: "在吗", when: .now, host: "mac") }
    try await store.linkCard(leaf.id, toSession: "s1")
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    try await recorder.update(sessionID: "s1", state: .settled)
    #expect(try await store.sayToLeaf(leaf.id, text: "在吗", when: .after, host: "mac").mode == .known(.send))
    await #expect(throws: CueStoreError.alreadyStarted("修乱序")) { try await store.startLeaf(leaf.id, host: "mac") }

    try await recorder.update(sessionID: "s1", state: .thinking)
    #expect(try await store.sayToLeaf(leaf.id, text: "停一下", when: .now, host: "mac").mode == .known(.steer))
    #expect(try await store.sayToLeaf(leaf.id, text: "做完再看", when: .after, host: "mac").mode == .known(.followUp))
    _ = try await store.createCard(body: "跑测试", under: leaf.id)
    let started = try await store.startLeaf(leaf.id, host: "mac")
    #expect(started.mode == .known(.followUp) && started.content == "跑测试")
  }

  @Test func 绑定_只绑叶子_草稿被取走_一个会话只绑一个叶子() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let first = try await store.createTask("修乱序", in: project.id)
    let second = try await store.createTask("改文案", in: project.id)
    let draft = try await store.createCard(body: "先复现\n再改", under: first.id)

    #expect(try await store.bindSession("s1", to: first.id) == "先复现\n再改")
    #expect(try await store.card(draft.id) == nil)
    let bound = try #require(try await store.task(boundTo: "s1"))
    #expect(bound.id == first.id && bound.status == .inProgress)
    #expect(try await store.bindSession("s2", to: first.id) == nil)  // 没有草稿
    #expect(try await store.task(boundTo: "s1") == nil)  // s1 没人绑了：第一个任务换成了 s2

    // 一个会话只绑一个叶子：绑到新叶子上时从旧的解开
    try await store.bindSession("s2", to: second.id)
    #expect(try await store.task(boundTo: "s2")?.id == second.id)
    #expect(try await store.card(first.id)?.piSessionID == nil)

    let step = try await store.createTask("复现", under: first.id)
    await #expect(throws: CueStoreError.notALeaf) { try await store.bindSession("s3", to: first.id) }
    await #expect(throws: CueStoreError.notATask) { try await store.bindSession("s3", to: try await store.createCard(in: nil, body: "灵感").id) }
    try await store.bindSession("s3", to: step.id)
    #expect(try await store.task(boundTo: "s3")?.id == step.id)
  }

  @Test func 能绑的叶子_没完成_没绑会话_步骤带上级() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let top = try await store.createTask("上线", in: project.id)
    let step = try await store.createTask("备份", under: top.id)
    let taken = try await store.createTask("已有会话", in: project.id)
    let finished = try await store.createTask("做完了", in: project.id)
    let loneBound = try await store.createTask("别的项目", in: nil)
    try await store.bindSession("s1", to: taken.id)
    try await store.setStatus(finished.id, .done)
    _ = loneBound

    let tasks = try await store.bindableTasks(in: project.id)
    #expect(tasks.map(\.task.id) == [step.id])
    #expect(tasks.first?.parent?.id == top.id)
  }
}
