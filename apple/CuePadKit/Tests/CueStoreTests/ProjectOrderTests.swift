import CueStore
import Foundation
import Testing

@Suite struct ProjectOrderTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func at(_ sql: String) throws { try RawDB(fixture.url).exec(sql) }

  @Test func 只有进展把项目往前排_收拾与会话变状态不动_置顶在前() async throws {
    let idea = try await store.createProject(name: "灵感", color: "#111")
    let work = try await store.createProject(name: "任务", color: "#111")
    let talk = try await store.createProject(name: "会话", color: "#111")
    let tidy = try await store.createProject(name: "收拾", color: "#111")
    let pinned = try await store.createProject(name: "置顶", color: "#111")
    try await store.updateProject(pinned.id) { $0.isPinned = true }
    let note = try await store.createCard(in: idea.id, body: "n")
    let task = try await store.createTask("t", in: work.id)
    let done = try await store.createTask("d", in: tidy.id)
    try await store.setStatus(done.id, .done)
    // 每次一个新的记录器：同一个会攒着上次的一轮开始时刻、还按间隔压写入。新一轮的开始时刻在隔开之后才取：
    // 库里时刻按毫秒存，先取再隔开会和上一步的写入落在同一毫秒，并列时按项目 id 排，顺序随机（#69）
    func session(_ state: PiWorkState, newTurn: Bool = false) async throws {
      await nextMillisecond()
      _ = try await PiStateRecorder(store: store, hostID: "mac").update(
        sessionID: "s1", state: state, title: "s", projectID: talk.id, turnStartedAt: newTurn ? .now : nil)
    }
    try await session(.thinking, newTurn: true)
    try at("UPDATE projects SET createdAt = 1000, modifiedAt = 1000")
    try at("UPDATE cards SET todoAt = 1000, startedAt = NULL, completedAt = 1000, modifiedAt = 1000 WHERE id = '\(done.id.uuidString.lowercased())'")
    try at("UPDATE cards SET modifiedAt = 3000 WHERE id = '\(note.id.uuidString.lowercased())'")
    try at("UPDATE cards SET todoAt = 2000, modifiedAt = 2000 WHERE id = '\(task.id.uuidString.lowercased())'")
    try at("UPDATE piSessionStates SET turnStartedAt = 1500, answeredAt = NULL, stateSince = 1500, modifiedAt = 1500")
    func order() async throws -> [String] { try await store.projects().map(\.name).filter { $0 != "默认" } }
    #expect(try await order() == ["置顶", "灵感", "任务", "会话", "收拾"])

    try await store.archive(done.id)
    try await store.unarchive(done.id)
    _ = try await store.trashCard(done.id)
    try await store.restoreCard(done.id)
    try await store.updateProject(tidy.id) { $0.name = "收拾好" }
    try await session(.waitingForUser)
    #expect(try await order() == ["置顶", "灵感", "任务", "会话", "收拾好"])

    await nextMillisecond()
    try await store.setStatus(task.id, .inProgress)
    #expect(try await order() == ["置顶", "任务", "灵感", "会话", "收拾好"])
    await nextMillisecond()
    try await store.updateCard(note.id) { $0.body = "n2" }
    #expect(try await order() == ["置顶", "灵感", "任务", "会话", "收拾好"])
    try await session(.thinking, newTurn: true)
    #expect(try await order() == ["置顶", "会话", "灵感", "任务", "收拾好"])
  }
}
