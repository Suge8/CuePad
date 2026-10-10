import CueStore
import Foundation
import Testing

@testable import CueStore

@Suite struct LibraryTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  // MARK: 排序

  @Test func newCardGoesOnTopAndMoveOnlyTouchesTheMovedCard() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let c1 = try await store.createCard(in: p.id, body: "1")
    let c2 = try await store.createCard(in: p.id, body: "2")
    let c3 = try await store.createCard(in: p.id, body: "3")
    #expect(bodies(try await store.cards(in: p.id)) == ["3", "2", "1"])

    let before = try await store.card(c2.id)
    try await store.moveCard(c3.id, to: .top(project: p.id), after: c1.id)
    #expect(bodies(try await store.cards(in: p.id)) == ["2", "1", "3"])
    #expect(try await store.card(c2.id) == before)
  }

  @Test func moveCardToInbox() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: p.id, body: "x")
    try await store.moveCard(card.id, to: .top(project: nil), after: nil)
    #expect(bodies(try await store.cards(in: nil)) == ["x"])
    #expect(try await store.cards(in: p.id).isEmpty)
  }

  @Test func moveSurvivesEqualSortKeysFromConcurrentDevices() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    for body in ["1", "2", "3"] { _ = try await store.createCard(in: p.id, body: body) }
    try RawDB(fixture.url).exec("UPDATE cards SET sortKey = 'V'")
    let start = try await store.cards(in: p.id)

    try await store.moveCard(start[0].id, to: .top(project: p.id), after: start[1].id)

    let end = try await store.cards(in: p.id)
    #expect(end.map(\.id) == [start[1].id, start[0].id, start[2].id])
    #expect(Set(end.map(\.sortKey)).count == 3)  // 键已重新分配，之后的移动不再依赖 id 打平
  }

  @Test func sortKeysStayStrictlyOrderedUnderRepeatedInsertion() {
    var keys = SortKey.sequence(count: 3)
    #expect(keys == keys.sorted())
    for _ in 0..<400 {
      let slot = Int.random(in: 0...keys.count)
      let lower = slot > 0 ? keys[slot - 1] : nil
      let upper = slot < keys.count ? keys[slot] : nil
      keys.insert(SortKey.between(lower, upper)!, at: slot)
    }
    #expect(keys == keys.sorted() && Set(keys).count == keys.count)
    #expect(!keys.contains { $0.hasSuffix("0") })
  }

  // MARK: 回收站

  @Test func trashingProjectHidesItsCardsAndRestoreBringsThemBackUntouched() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let kept = try await store.createCard(in: p.id, body: "kept")
    let alone = try await store.createCard(in: p.id, body: "trashed earlier")
    try await store.trashCard(alone.id)

    try await store.trashProject(p.id)
    #expect(try await store.cards(in: p.id).isEmpty)
    #expect(try await store.projects().isEmpty)
    #expect(try await store.trashedProjects().map(\.id) == [p.id])
    #expect(try await store.card(kept.id)?.deletedAt == nil)  // 随项目进回收站由项目推导，不逐卡记录

    try await store.restoreProject(p.id)
    #expect(bodies(try await store.cards(in: p.id)) == ["kept"])  // 早先单独删除的卡仍在回收站
    #expect(try await store.trashedCards().map(\.id) == [alone.id])
  }

  @Test func cardRestoredIntoTrashedProjectFallsBackToInbox() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: p.id, body: "x")
    try await store.trashCard(card.id)
    try await store.trashProject(p.id)

    try await store.restoreCard(card.id)

    #expect(try await store.cards(in: nil).map(\.id) == [card.id])
  }

  @Test func purgeProjectRemovesItsCardsButKeepsCardsAlreadyInTrash() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let withProject = try await store.createCard(in: p.id, body: "goes with project")
    let alone = try await store.createCard(in: p.id, body: "trashed earlier")
    try await store.trashCard(alone.id)
    try await store.trashProject(p.id)

    try await store.purgeProject(p.id)

    #expect(try await store.card(withProject.id) == nil)
    #expect(try await store.card(alone.id)?.projectID == nil)
    #expect(try await store.project(p.id) == nil)
  }

  @Test func emptyTrashRemovesTrashedCardsAndProjectsWithTheirCards() async throws {
    let live = try await store.createProject(name: "live", color: "#111")
    let gone = try await store.createProject(name: "gone", color: "#222")
    let inGone = try await store.createCard(in: gone.id, body: "in gone")
    let dead = try await store.createCard(in: live.id, body: "dead")
    let alive = try await store.createCard(in: live.id, body: "alive")
    try await store.trashProject(gone.id)
    try await store.trashCard(dead.id)

    try await store.emptyTrash()

    #expect(try await store.card(inGone.id) == nil)
    #expect(try await store.card(dead.id) == nil)
    #expect(try await store.card(alive.id) != nil)
    #expect(try await store.projects().map(\.id) == [live.id])
    #expect(try await store.trashedProjects().isEmpty)
  }

  // MARK: 卡片

  @Test func cardFieldsRoundTrip() async throws {
    let card = try await store.createCard(in: nil, body: "hi {{name}}")
    try await store.updateCard(card.id) {
      $0.isPinned = true
      $0.variableValues = ["name": "Pi"]
    }
    let row = try await store.card(card.id)
    #expect(row?.variableValues == ["name": "Pi"])
    #expect(row?.isPinned == true)
  }

  // MARK: 任务

  @Test func tasksStackNewestOnTopAndCompletedLeaveTheActiveList() async throws {
    _ = try await store.createTask("a", in: nil)
    let b = try await store.createTask("b", in: nil)
    _ = try await store.createTask("c", in: nil)
    func active() async throws -> [String] { try await store.tasks(.todo).flatMap(\.tasks).map(\.body) }
    #expect(try await active() == ["c", "b", "a"])

    try await store.setStatus(b.id, .done)
    #expect(try await active() == ["c", "a"])
    #expect(try await store.tasks(.done).flatMap(\.tasks).map(\.body) == ["b"])
  }

  @Test func blankTaskContentIsRejected() async throws {
    await #expect(throws: CueStoreError.blankTaskContent) {
      try await store.createTask("   ", in: nil)
    }
  }

  // MARK: 发送记录与 Pi 会话索引

  @Test func sendRecordKeepsContentSnapshotAfterCardIsPurged() async throws {
    let card = try await store.createCard(in: nil, body: "prompt v1")
    try await store.recordSend(
      "prompt v1", to: SendTarget(kind: .piSession, name: "fix bug", ref: "s1"),
      card: card.id)
    try await store.updateCard(card.id) { $0.body = "prompt v2" }
    try await store.purgeCard(card.id)

    let records = try await store.sendRecords()
    #expect(records.map(\.content) == ["prompt v1"])
    #expect(records.first?.cardID == nil)
    #expect(records.first?.targetName == "fix bug")
  }

  // MARK: 项目目录（本机）

  @Test func projectDirectoryIsPerDeviceAndDiesWithTheProject() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    #expect(try await store.directory(of: p.id) == nil)

    try await store.setDirectory("/work/a", for: p.id)
    try await store.setDirectory("/work/b", for: p.id)
    #expect(try await store.directory(of: p.id) == "/work/b")
    #expect(try await store.projectDirectories() == [p.id: "/work/b"])

    try await store.setDirectory(nil, for: p.id)
    #expect(try await store.directory(of: p.id) == nil)

    try await store.setDirectory("/work/c", for: p.id)
    try await store.trashProject(p.id)
    try await store.purgeProject(p.id)
    #expect(try await store.projectDirectories().isEmpty)
  }

  @Test func projectDirectoryChangesWakeObservers() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    var values = store.observe([.projectDirectories]) { try $0.projectDirectories() }.makeAsyncIterator()
    #expect(try await values.next() == [:])
    try await store.setDirectory("/work/a", for: p.id)
    #expect(try await values.next() == [p.id: "/work/a"])
  }

  @Test func reopeningTheFileKeepsData() async throws {
    let card = try await store.createCard(in: nil, body: "persisted")
    let reopened = try CueStore(url: fixture.url)
    #expect(try await reopened.card(card.id)?.body == "persisted")
  }

  /// 结构 17 的库（会话记录还没有上下文余量与命令清单两列、没有预览表、对话里只有工具个数）就地升级，已有的会话记录不丢，
  /// 新列可写，预览可用；会话文件的检查点作废（下次从头读，补出旧对话的工具活动）。
  @Test func schema17LibraryUpgradesInPlaceAndKeepsSessionRecords() async throws {
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .settled, title: "旧会话")
    try await store.upsertPiSession(PiSession(id: "s1", path: "/s/s1.jsonl", cwd: "/w", lastActivityAt: .now), checkpoint: Data([1]), host: "mac")
    try RawDB(fixture.url).exec(
      """
      ALTER TABLE piSessionStates DROP COLUMN context; ALTER TABLE piSessionStates DROP COLUMN commands; DROP TABLE previews;
      ALTER TABLE piMessages DROP COLUMN tools; ALTER TABLE piMessages ADD COLUMN toolCount INTEGER NOT NULL DEFAULT 0;
      DROP INDEX piSessionStates_sessionID; DROP INDEX cards_deletedAt; PRAGMA user_version = 17;
      """)

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.piCheckpoint(of: "s1") == nil)
    #expect(try await upgraded.allPiSessionStates().map(\.title) == ["旧会话"])
    try await PiStateRecorder(store: upgraded, hostID: "mac").update(
      sessionID: "s1", state: .settled, context: PiContextUsage(tokens: 1, window: 2))
    #expect(try await upgraded.allPiSessionStates().first?.context == PiContextUsage(tokens: 1, window: 2))
    #expect(try await upgraded.previews(of: "s1").isEmpty)
  }

  /// 更新版本建的库与更早版本建的库（不再升级旧结构）都拒绝打开，不在错位的表结构上读写。
  @Test(arguments: [(22, CueStoreError.unsupportedSchemaVersion(22)), (16, .schemaTooOld(16))])
  func libraryFromAnotherSchemaVersionIsRefused(version: Int, error: CueStoreError) throws {
    let url = fixture.directory.appending(path: "other/cuepad.db")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try RawDB(url).exec("CREATE TABLE cards (id TEXT PRIMARY KEY NOT NULL) STRICT; PRAGMA user_version = \(version);")
    #expect(throws: error) { try CueStore(url: url) }
  }
}
