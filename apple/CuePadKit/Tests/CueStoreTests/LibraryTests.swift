import CueStore
import Foundation
import Testing

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

  @Test func cardRestoredIntoTrashedProjectFallsBackToUnfiled() async throws {
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

  // MARK: 发送记录

  @Test func sendRecordKeepsContentSnapshotAfterCardIsPurged() async throws {
    let card = try await store.createCard(in: nil, body: "prompt v1")
    try await store.recordSend(
      "prompt v1", to: SendTarget(kind: .piSession, name: "fix bug", ref: "s1"),
      card: card.id)
    try await store.updateCard(card.id) { $0.body = "prompt v2" }
    try await store.purgeCard(card.id)

    #expect(try RawDB(fixture.url).rows("SELECT content, cardID, targetName FROM sendRecords") == [["prompt v1", "NULL", "fix bug"]])
  }

  // MARK: 结构版本

  @Test func reopeningTheFileKeepsData() async throws {
    let card = try await store.createCard(in: nil, body: "persisted")
    let reopened = try CueStore(location: .isolated(fixture.directory))
    #expect(try await reopened.card(card.id)?.body == "persisted")
  }

  /// 结构 50 的库里分割线是私有标记 `---split---`（独占一行）：升到 51 时换成 Markdown 的 `---`，行里夹着的不是分割线、不动；
  /// 改过的卡带新的修改时间（同步出去），回收站里的也换。升到 56 时已有的提问照当时的选项认出类别、范围是关联任务所在的项目
  /// （带新的修改时间同步出去），目录绑定去掉 Mac 名、绑定照旧在。
  @Test func schema50LibraryUpgradesDividersAndQuestions() async throws {
    let card = try await store.createCard(in: nil, body: "上\n---split---\n中 ---split--- 夹着\n  ---split---  \n下")
    let plain = try await store.createCard(in: nil, body: "没有分割线")
    let trashed = try await store.createCard(in: nil, body: "甲\n---split---\n乙")
    _ = try await store.trashCard(trashed.id)
    let before = try #require(try await store.card(card.id)).modifiedAt
    let untouched = try #require(try await store.card(plain.id)).modifiedAt
    let demo = try await store.createProject(name: "演示", color: "#111")
    let task = try await store.createTask("修好登录页", in: demo.id)
    try await store.setDirectory("/work/demo", for: demo.id)
    try await store.publishDirectoryBindings(host: "mac")
    // 退回 50：撤掉 52、54、56、57、59、60 加的列、55、57、60 加的索引与 58、60 加的表，放回 56 删掉的列（53 重建触发器、55 重建的类型索引，留着新的照样能升）
    let added = try RawDB(fixture.url).rows(
      """
      SELECT name FROM sqlite_master WHERE name GLOB '*_modified' OR name IN
        ('syncRecords_pushed', 'piSessionStates_folder', 'piMessages_sessionID_at', 'piSessions_agent', 'cueMessages_open', 'cueMessages_answered')
      """)
    try RawDB(fixture.url).exec(
      """
      ALTER TABLE cueState DROP COLUMN woke; ALTER TABLE cueState DROP COLUMN context; ALTER TABLE cueState DROP COLUMN leftToYou;
      ALTER TABLE macAgents DROP COLUMN name;
      ALTER TABLE cueMessages DROP COLUMN ask; ALTER TABLE cueMessages DROP COLUMN askAction; ALTER TABLE cueMessages DROP COLUMN askRule; ALTER TABLE cueMessages DROP COLUMN askShots;
      ALTER TABLE piMessages DROP COLUMN question;
      ALTER TABLE directoryBindings ADD COLUMN hostName TEXT NOT NULL DEFAULT 'Studio';
      \(added.map { "DROP INDEX \($0[0]);" }.joined()) DROP TABLE cueRead; DROP TABLE sessionViewers; PRAGMA user_version = 50;
      INSERT INTO cueMessages (id, author, text, choices, urgent, taskID, createdAt, modifiedAt) VALUES
        ('\(UUID().uuidString.lowercased())', 'cue', '要推送吗？', '["允许一次","以后推送都不用问"]', 0, '\(task.id.uuidString.lowercased())', 1, 1),
        ('\(UUID().uuidString.lowercased())', 'cue', '按规矩要先问', '["允许一次"]', 0, NULL, 2, 2);
      """)

    let upgraded = try CueStore(location: .isolated(fixture.directory))
    let converted = try #require(try await upgraded.card(card.id))
    #expect(converted.body == "上\n---\n中 ---split--- 夹着\n---\n下" && converted.modifiedAt > before)
    #expect(try await upgraded.card(plain.id)?.modifiedAt == untouched)
    #expect(try await upgraded.trashedCards().map(\.body) == ["甲\n---\n乙"])
    let questions = try await upgraded.cueMessagesWaitingForYou()
    #expect(questions.map(\.asked) == [CueAllow(.push, project: demo.id), CueAllow(.rule, project: nil)])
    #expect(questions.allSatisfy { $0.modifiedAt > Date(timeIntervalSince1970: 1) })
    #expect(try await upgraded.directoryBindings().map(\.folder) == ["demo"])
  }

  /// 更新版本建的库与更早版本建的库（不再升级旧结构）都拒绝打开，不在错位的表结构上读写。
  @Test(arguments: [
    (CueStore.supportedSchemaVersions.upperBound + 1, CueStoreError.unsupportedSchemaVersion(CueStore.supportedSchemaVersions.upperBound + 1)),
    (CueStore.supportedSchemaVersions.lowerBound - 1, .schemaTooOld(CueStore.supportedSchemaVersions.lowerBound - 1)),
  ])
  func libraryFromAnotherSchemaVersionIsRefused(version: Int, error: CueStoreError) throws {
    let url = fixture.directory.appending(path: "other/cuepad.db")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try RawDB(url).exec("CREATE TABLE cards (id TEXT PRIMARY KEY NOT NULL) STRICT; PRAGMA user_version = \(version);")
    #expect(throws: error) { try CueStore(location: .isolated(url.deletingLastPathComponent())) }
  }
}
