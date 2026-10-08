import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing

/// 任务只是一件要做成的事（标题与可选一句说明），要交给 Agent 的话是挂在它下面的灵感——任务里叫"提示词"。
/// 提示词交给 Agent 后，那个会话这一轮做完（发出之后歇下来）它就算"已回复"：由发送记录与会话状态推出，不另存字段。
@Suite struct PromptTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

  // MARK: 结构 16 的库升级

  private func upgraded() throws -> (CueStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "prompt-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "cuepad.db")
    let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/library-v16.sqlite")
    try FileManager.default.copyItem(at: source, to: url)
    return (try CueStore(url: url), url)
  }

  private func findTask(_ title: String, in store: CueStore) async throws -> Card {
    try #require(try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).first { CueSummary($0.body).title == title })
  }

  /// 夹具（结构 16）：任务"修重连排序"正文三行、交给过 atlas（发送记录与一条投送请求）、下面挂着一条灵感与一个子任务；
  /// "续费域名"只有标题；回收站里的"旧任务"正文两行。
  @Test func 升级后任务正文的要求成为它的第一条提示词_标题留给任务() async throws {
    let (store, _) = try upgraded()
    let task = try await findTask("修重连排序", in: store)
    #expect(task.body == "修重连排序")
    let children = try await store.children(of: task.id)
    #expect(children.map(\.body) == ["跑一下 scheduler 的测试，找出 5 人以上时谁被排到了最前\n先别改代码", "复现记录", "补重连用例"])
    let prompt = children[0]
    #expect(!prompt.isTask && prompt.projectID == task.projectID)
    #expect(try await findTask("续费域名", in: store).body == "续费域名")
    #expect(try await store.children(of: try await findTask("续费域名", in: store).id).isEmpty)
  }

  @Test func 升级后发送记录投送请求与会话跟到那条提示词_任务仍在进行中() async throws {
    let (store, _) = try upgraded()
    let task = try await findTask("修重连排序", in: store)
    let prompt = try #require(try await store.children(of: task.id).first)
    #expect(try await store.sendRecords().compactMap(\.cardID) == [prompt.id])
    #expect(try await store.deliveryRequests().compactMap(\.cardID) == [prompt.id])
    #expect(prompt.piSessionID == "s1")
    #expect(task.status == .inProgress && task.piSessionID == "s1")
  }

  @Test func 两台设备各自升级得到同一条提示词_待上传() async throws {
    let (store, _) = try upgraded()
    let (other, _) = try upgraded()
    let prompt = try #require(try await store.children(of: try await findTask("修重连排序", in: store).id).first)
    let same = try #require(try await other.children(of: try await findTask("修重连排序", in: other).id).first)
    #expect(prompt.id == same.id)
    let pending = Set(try await store.pendingSync().saves.map(\.id))
    #expect(pending.contains(prompt.id.uuidString.lowercased()))
  }

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

  @Test func 写一条提示词_接在任务的下级最后() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let first = try await store.createCard(body: "先复现", under: task.id)
    let second = try await store.createCard(body: "", under: task.id)
    #expect(try await store.children(of: task.id).map(\.id) == [first.id, second.id])
    #expect(!second.isTask && second.parentID == task.id)
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

  @Test func 只复制或发到应用不算交给Agent() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let prompt = try await store.createCard(body: "先复现", under: task.id)
    try await store.recordSend(prompt.body, to: SendTarget(kind: .clipboard, name: "剪贴板", ref: nil), card: prompt.id)
    #expect(try await replied(task.id) == [false])
  }

  @Test func 提示词交给会话_它的任务关联到那个会话并进行中() async throws {
    let task = try await store.createTask("修重连排序", in: nil)
    let prompt = try await store.createCard(body: "先复现", under: task.id)
    try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
    let after = try #require(try await store.card(task.id))
    #expect(after.status == .inProgress && after.piSessionID == "s1")
    #expect(try await store.card(prompt.id)?.piSessionID == "s1")
  }
}
