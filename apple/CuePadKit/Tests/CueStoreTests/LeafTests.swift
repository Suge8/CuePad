import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing

/// 任务 → 步骤 → 会话：叶子（没有步骤的任务）才有草稿与会话；一个叶子最多一个会话，一个会话可以绑好几个叶子。
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

  /// 终端里开的 Claude Code、Codex 会话不是什么都做得到（`AgentCapabilities`）：Cue 对它们的开工、停止、收尾与界面同一组规则——
  /// 收不了图片的只交文字，停不了这一轮就报停不了，结束不了的会话事做完了也留着。
  @Test func 交给其他Agent的会话_只做它做得到的() async throws {
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    let claude = try await store.createTask("修乱序", in: nil)
    try await store.linkCard(claude.id, toSession: "claude-1")
    try await recorder.update(sessionID: "claude-1", state: .settled, agent: .claudeCode)
    let image = try store.files.store(pngData(width: 8, height: 8, shade: 0.5))
    _ = try await store.createCard(body: "看截图\n\(CueFormat.imageMarkup(id: image))", under: claude.id)
    #expect(try await store.startLeaf(claude.id, host: "mac").content == "看截图")
    try await recorder.update(sessionID: "claude-1", state: .thinking, agent: .claudeCode)
    await #expect(throws: CueStoreError.cannotStop("修乱序")) { try await store.stopLeaf(claude.id, host: "mac") }

    let codex = try await store.createTask("改文案", in: nil)
    try await store.linkCard(codex.id, toSession: "codex-1")
    try await recorder.update(sessionID: "codex-1", state: .settled, agent: .codex)
    #expect(try await store.completeTask(codex.id, requireStepsDone: true, cue: true).isEmpty)
    #expect(try await store.card(codex.id)?.status == .done)

    // 你收下 Cue 请你验收的事：任务照样完成，结束不了的会话照样留着
    let accepted = try await store.createTask("改样式", in: nil)
    try await store.linkCard(accepted.id, toSession: "codex-2")
    try await recorder.update(sessionID: "codex-2", state: .settled, agent: .codex)
    let question = try await store.askToAccept(accepted.id, evidence: "- 样式对上了").message
    #expect(try await store.endCueQuestion(question.id, .answered(CueAcceptance.accept)).isEmpty)
    #expect(try await store.card(accepted.id)?.status == .done)
  }

  /// 一个会话绑好几个叶子、草稿接进回复框、做完才结束会话，见 App 的流程测试（`TaskFlowTests`）；这里是绑定本身的规则。
  @Test func 绑定_只绑叶子_改绑换掉原来的_解绑不改任务状态() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let first = try await store.createTask("修乱序", in: project.id)
    let second = try await store.createTask("改文案", in: project.id)
    try await store.bindSession("s1", to: first.id)
    try await store.bindSession("s1", to: second.id)
    #expect(try await store.card(second.id)?.status == .inProgress)

    // 一个叶子最多一个会话：改绑换掉原来的；解绑后会话照常、任务状态不变
    try await store.bindSession("s2", to: first.id)
    #expect(try await store.tasks(boundTo: "s1").map(\.task.id) == [second.id])
    try await store.unbindSession(from: second.id)
    #expect(try await store.tasks(boundTo: "s1").isEmpty)
    #expect(try await store.card(second.id)?.status == .inProgress)

    let step = try await store.createTask("复现", under: second.id)
    await #expect(throws: CueStoreError.notALeaf) { try await store.bindSession("s3", to: second.id) }
    await #expect(throws: CueStoreError.notATask) { try await store.bindSession("s3", to: try await store.createCard(in: nil, body: "灵感").id) }
    try await store.bindSession("s3", to: step.id)
    #expect(try await store.tasks(boundTo: "s3").map { [$0.task.id, $0.parent?.id] } == [[step.id, second.id]])
  }

  /// 从任务开了新会话、又亲手改绑：以后一次为准，那个新会话的记录再写（或同步过来）也不把任务抢回去。
  @Test func 开新会话后又改绑_不被新会话抢回() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let task = try await store.createTask("修乱序", in: project.id)
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    _ = try await store.requestLaunch(PiLaunch(project: project.id, prompt: "修乱序", token: "t-new"), title: "修乱序", on: "mac-a", card: task.id)
    try await recorder.update(sessionID: "s-new", state: .thinking, title: "修乱序", launchToken: "t-new")
    #expect(try await store.card(task.id)?.piSessionID == "s-new")

    try await store.bindSession("s-old", to: task.id)
    try await recorder.update(sessionID: "s-new", state: .settled, title: "修乱序", launchToken: "t-new")

    #expect(try await store.card(task.id)?.piSessionID == "s-old")
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
