import CueStore
import CueTestSupport
import Foundation
import Testing

/// 项目只有一种顺序：置顶在前，其余按最近活动——项目自身、其下卡片（灵感与任务）的最近修改中最晚的。
/// Pi 会话的状态变化不算：Agent 一变状态项目就换位置，⌘1–9 对应的项目会跟着变。
@Suite struct ProjectOrderTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func at(_ table: String, _ id: UUID, _ millis: Int, column: String = "modifiedAt") throws {
    try RawDB(fixture.url).exec("UPDATE \(table) SET \(column) = \(millis) WHERE id = '\(id.uuidString.lowercased())'")
  }

  @Test func pinnedFirstThenMostRecentEditAcrossCardsAndTasks_PiSessionStateChangesDoNotMoveProjects() async throws {
    let byCard = try await store.createProject(name: "卡片新", color: "#111")
    let byTask = try await store.createProject(name: "任务新", color: "#111")
    let byPi = try await store.createProject(name: "Pi 新", color: "#111")
    let quiet = try await store.createProject(name: "安静", color: "#111")
    let pinned = try await store.createProject(name: "置顶", color: "#111")
    try await store.updateProject(pinned.id) { $0.isPinned = true }
    let card = try await store.createCard(in: byCard.id, body: "c")
    let task = try await store.createTask("t", in: byTask.id)
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .thinking, title: "s", projectID: byPi.id)
    for project in [byCard, byTask, byPi, quiet, pinned] { try at("projects", project.id, 1_000) }
    try at("projects", quiet.id, 2_000)
    try at("cards", card.id, 5_000)
    try at("cards", task.id, 4_000)
    let state = try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
    try at("piSessionStates", state.id, 1_000)
    try at("piSessionStates", state.id, 6_000, column: "stateSince")

    #expect(try await store.projects().map(\.name) == ["置顶", "卡片新", "任务新", "安静", "Pi 新"])
  }

  /// 本地不再有项目的手动排序键，同步记录也不再写它。
  @Test func projectsCarryNoSortKey() async throws {
    _ = try await store.createProject(name: "P", color: "#111")
    #expect(try RawDB(fixture.url).rows("SELECT name FROM pragma_table_info('projects') WHERE name = 'sortKey'").isEmpty)
  }
}
