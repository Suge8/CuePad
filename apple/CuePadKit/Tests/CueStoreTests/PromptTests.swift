import CueStore
import CueTestSupport
import Foundation
import Testing

/// 任务只是一件要做成的事（标题与可选一句说明），要交给 Agent 的话是挂在它下面的灵感——任务里叫"提示词"。
/// 提示词交给 Agent 后，那个会话这一轮做完（发出之后歇下来）它就算"已回复"：由发送记录与会话状态推出，不另存字段。
@Suite struct PromptTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

  // MARK: 设为任务

  @Test func 多行的灵感设为任务_第一行是任务_其余成为它的提示词() async throws {
    let idea = try await store.createCard(in: nil, body: "上线前检查\n把 changelog 过一遍\n看下崩溃率")
    try await store.setTodo(idea.id, true)
    #expect(try await store.card(idea.id)?.body == "上线前检查")
    #expect(try await store.children(of: idea.id).map(\.body) == ["把 changelog 过一遍\n看下崩溃率"])

    let single = try await store.createCard(in: nil, body: "续费域名")
    try await store.setTodo(single.id, true)
    #expect(try await store.children(of: single.id).isEmpty)
  }

  // MARK: 已回复

  private func replied(_ task: UUID) async throws -> [Bool] {
    (try await store.childMarks(of: task)[task] ?? []).filter { !$0.isTask }.map(\.isDone)
  }

  @Test func 提示词交给会话后_那一轮做完才算已回复_再交一次又回到处理中() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let prompt = try await store.createCard(body: "先复现", under: task.id)
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    _ = try await recorder.update(sessionID: "s1", state: .settled, title: "atlas", times: PiTimes(stateSince: .now, busySince: nil))
    try await Task.sleep(for: .milliseconds(5))  // 发出晚于会话上一次歇下（时刻按毫秒比先后）

    try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
    #expect(try await replied(task.id) == [false])  // 会话还停在发出之前的那次"歇下"
    _ = try await recorder.update(sessionID: "s1", state: .thinking, times: PiTimes(stateSince: .now, busySince: .now))
    try await Task.sleep(for: .milliseconds(5))
    _ = try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: .now, busySince: nil))
    #expect(try await replied(task.id) == [true])

    try await Task.sleep(for: .milliseconds(5))
    try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
    #expect(try await replied(task.id) == [false])
  }

  /// 交给 atlas，它这一轮做完（发出之后歇下）。
  private func reply(_ prompt: Card, _ recorder: PiStateRecorder) async throws {
    try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
    try await enter(.thinking, recorder)
    try await enter(.settled, recorder)
  }

  private func enter(_ state: PiWorkState, _ recorder: PiStateRecorder) async throws {
    try await Task.sleep(for: .milliseconds(5))
    _ = try await recorder.update(sessionID: "s1", state: state, title: "atlas", times: PiTimes(stateSince: .now, busySince: nil))
  }

  @Test func 手机重发后Mac还没执行_在路上的请求优先_不算已回复_状态点跟着那个会话() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let prompt = try await store.createCard(body: "先复现", under: task.id)
    try await reply(prompt, PiStateRecorder(store: store, hostID: "mac-a"))
    #expect(try await replied(task.id) == [true])

    let request = try await store.requestDelivery("先复现，这次带上日志", to: SendTarget(kind: .piSession, name: "notes", ref: "s2"), on: "mac-a", card: prompt.id)
    #expect(try await replied(task.id) == [false])
    #expect(try await store.handedSessions()[prompt.id] == .session("s2"))

    // Mac 执行了、记下发送，那个会话还没做完：仍不算
    try await store.recordSend(request.content, to: request.target, card: prompt.id)
    #expect(try await replied(task.id) == [false])
  }

  @Test func 会话没回复就结束了_不算已回复_回复过再结束仍算() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let prompt = try await store.createCard(body: "先复现", under: task.id)
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
    try await enter(.thinking, recorder)
    try await Task.sleep(for: .milliseconds(5))
    try await recorder.end(sessionID: "s1")
    #expect(try await replied(task.id) == [false])

    // 对话里有它在发出之后的一条回答：回复过了，结束不影响
    try await store.writePiTranscript(PiTranscript(
      sessionID: "s1", messages: [PiChatMessage(sessionID: "s1", entryID: "p1", seq: 1, role: .pi, text: "复现了", at: .now)],
      recap: PiRecap(lastPrompt: nil, lastReply: "复现了", pendingPrompt: nil)))
    #expect(try await replied(task.id) == [true])
  }

  /// 同一个会话连着交几条提示词：每条的"已回复"只看它自己那一轮，后面又交了一条、会话又在忙，不改前面的。
  @Test func 同一会话连着交几条提示词_前面的已回复不因后面又交了一条而倒退() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let first = try await store.createCard(body: "先复现", under: task.id)
    let second = try await store.createCard(body: "再改排序", under: task.id)
    let third = try await store.createCard(body: "补用例", under: task.id)
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    var seq = 0
    func round(_ prompt: Card, answered: Bool) async throws {
      try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
      try await enter(.thinking, recorder)
      guard answered else { return }
      seq += 1
      try await Task.sleep(for: .milliseconds(5))
      try await store.writePiTranscript(PiTranscript(
        sessionID: "s1", messages: (1...seq).map { PiChatMessage(sessionID: "s1", entryID: "p\($0)", seq: Int64($0), role: .pi, text: "做完 \($0)", at: .now) },
        recap: PiRecap(lastPrompt: nil, lastReply: "做完 \(seq)", pendingPrompt: nil)))
      try await enter(.settled, recorder)
    }
    try await round(first, answered: true)
    try await round(second, answered: true)
    try await round(third, answered: false)

    #expect(try await replied(task.id) == [true, true, false])
  }

  /// "已回复"靠会话的对话推出，所以清理对话（会话安静 7 天后）跳过仍被提示词引用的会话：整段对话留着，已回复不退回；
  /// 提示词归档或删除后（没人引用了）照常清理。
  @Test func 对话清理跳过仍被提示词引用的会话_已回复的提示词不退回() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let prompt = try await store.createCard(body: "先复现", under: task.id)
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
    try await enter(.thinking, recorder)
    try await Task.sleep(for: .milliseconds(5))
    try await store.writePiTranscript(PiTranscript(
      sessionID: "s1", messages: [PiChatMessage(sessionID: "s1", entryID: "p1", seq: 1, role: .pi, text: "复现了", at: .now)],
      recap: PiRecap(lastPrompt: nil, lastReply: "复现了", pendingPrompt: nil)))
    try await enter(.settled, recorder)
    try await recorder.end(sessionID: "s1")
    // 没有提示词引用的另一个会话，对话照常被清理
    try await store.writePiTranscript(PiTranscript(
      sessionID: "s2", messages: [PiChatMessage(sessionID: "s2", entryID: "q1", seq: 1, role: .pi, text: "别的", at: .now)],
      recap: PiRecap(lastPrompt: nil, lastReply: "别的", pendingPrompt: nil)))
    #expect(try await replied(task.id) == [true])
    let later = Date.now.addingTimeInterval(30 * 86_400)

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: later)

    #expect(try await replied(task.id) == [true])
    #expect(try await store.piMessages(of: "s1").count == 1)
    #expect(try await store.piMessages(of: "s2").isEmpty)

    try await store.archive(prompt.id)
    try await store.prunePiMessages(olderThan: 7 * 86_400, now: later)
    #expect(try await store.piMessages(of: "s1").isEmpty)
  }

}
