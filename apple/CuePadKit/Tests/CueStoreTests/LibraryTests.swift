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

  /// 把新建的库退回结构 `version`（48–50）：撤掉 52、54 加的列与 55 加的索引（53 重建触发器、55 重建的类型索引，留着新的照样能升），
  /// 退到 48 再撤掉 49 加的允许清单列。50 只改数据，49 → 50 的结构相同。
  private func downgrade(to version: Int) throws {
    let added = try RawDB(fixture.url).rows(
      """
      SELECT name FROM sqlite_master WHERE name GLOB '*_modified' OR name IN
        ('syncRecords_pushed', 'piSessionStates_folder', 'piMessages_sessionID_at', 'piSessions_agent', 'cueMessages_open')
      """)
    try RawDB(fixture.url).exec(
      """
      ALTER TABLE cueState DROP COLUMN woke; ALTER TABLE cueState DROP COLUMN context; ALTER TABLE macAgents DROP COLUMN name;
      \(added.map { "DROP INDEX \($0[0]);" }.joined()) \(version < 49 ? "ALTER TABLE cueProfile DROP COLUMN allows;" : "")
      PRAGMA user_version = \(version);
      """)
  }

  /// 结构 48 的库（手机停在发出 49 之前的版本）照样升上来，不按"太旧"拒绝：记忆里"以后……都不用问"的规矩行换成允许清单里的一项、
  /// 那一行忘掉；写着项目名却对不上唯一一个项目的留在记忆里。还开着的提问去掉"拒绝"。
  @Test func schema48LibraryUpgradesAndMovesRulesIntoAllows() async throws {
    let project = try await store.createProject(name: "甲", color: "#111")
    _ = try await store.updateCueProfile { _ in }
    let push = try await store.noteCueLine("以后推送都不用问", source: .you, pinned: true).line
    let delete = try await store.noteCueLine("以后删除都不用问（项目「甲」）", source: .you, pinned: true).line
    let unknown = try await store.noteCueLine("以后发布或部署都不用问（项目「乙」）", source: .you, pinned: true).line
    let question = try await store.addCueMessage(.cue, text: "推吗？", ask: .push)
    try downgrade(to: 48)
    try RawDB(fixture.url).exec(
      "UPDATE cueMessages SET choices = '[\"允许一次\",\"拒绝\"]' WHERE id = '\(question.id.uuidString.lowercased())';")

    let upgraded = try CueStore(location: .isolated(fixture.directory))
    #expect(try await upgraded.cueProfile()?.allows == [CueAllow(.push, project: nil), CueAllow(.delete, project: project.id)])
    let lines = try await upgraded.cueMemory().lines
    #expect(lines.first { $0.id == push.id }?.deletedAt != nil)
    #expect(lines.first { $0.id == delete.id }?.deletedAt != nil)
    #expect(lines.first { $0.id == unknown.id }?.deletedAt == nil)
    #expect(try await upgraded.cueMessages().first { $0.id == question.id }?.choices == ["允许一次"])
  }

  /// 结构 49 的库里任务下挂着提示词（不是资料的灵感）：升到 50 时按先后拼进任务的正文、删掉；投送请求与发送记录改指任务，
  /// 提示词记着的会话交给还没会话的任务；资料与回收站里的不动，任务带新的修改时间。
  @Test func schema49LibraryFoldsPromptsIntoTasks() async throws {
    let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")
    let task = try await store.createTask("修乱序", in: nil)
    let ideas = [
      try await store.createCard(in: nil, body: "先复现"), try await store.createCard(in: nil, body: "再改排序"),
      try await store.createCard(in: nil, body: "常用说明"), try await store.createCard(in: nil, body: "删掉的"),
    ]
    let (first, second, resource, trashed) = (ideas[0], ideas[1], ideas[2], ideas[3])
    try await store.updateCard(resource.id) { $0.isPinned = true }
    _ = try await store.trashCard(trashed.id)
    let request = try await store.requestDelivery(second.body, to: atlas, on: "mac", card: second.id)
    try await store.recordSend(second.body, to: atlas, card: second.id)
    let before = try #require(try await store.card(task.id)).modifiedAt
    let parents = zip(ideas, ["b", "c", "a", "d"]).map {
      "UPDATE cards SET parentID = '\(task.id.uuidString.lowercased())', sortKey = '\($1)' WHERE id = '\($0.id.uuidString.lowercased())';"
    }.joined()
    try downgrade(to: 49)
    try RawDB(fixture.url).exec(parents + "UPDATE cards SET piSessionID = 's1' WHERE id = '\(second.id.uuidString.lowercased())';")

    let upgraded = try CueStore(location: .isolated(fixture.directory))
    let folded = try #require(try await upgraded.card(task.id))
    #expect(folded.body == "修乱序\n\n先复现\n\n再改排序" && folded.piSessionID == "s1" && folded.modifiedAt > before)
    #expect(try await upgraded.children(of: task.id).map(\.id) == [resource.id])
    #expect(try await upgraded.card(first.id) == nil)
    #expect(try await upgraded.card(second.id) == nil)
    #expect(try await upgraded.trashedCards().map(\.id) == [trashed.id])
    #expect(try await upgraded.deliveryRequests().first { $0.id == request.id }?.cardID == task.id)
    #expect(try RawDB(fixture.url).rows("SELECT cardID FROM sendRecords") == [[task.id.uuidString.lowercased()]])
  }

  /// 结构 50 的库里分割线是私有标记 `---split---`（独占一行）：升到 51 时换成 Markdown 的 `---`，行里夹着的不是分割线、不动；
  /// 改过的卡带新的修改时间（同步出去），回收站里的也换。
  @Test func schema50LibraryWritesDividersAsMarkdown() async throws {
    let card = try await store.createCard(in: nil, body: "上\n---split---\n中 ---split--- 夹着\n  ---split---  \n下")
    let plain = try await store.createCard(in: nil, body: "没有分割线")
    let trashed = try await store.createCard(in: nil, body: "甲\n---split---\n乙")
    _ = try await store.trashCard(trashed.id)
    let before = try #require(try await store.card(card.id)).modifiedAt
    let untouched = try #require(try await store.card(plain.id)).modifiedAt
    try downgrade(to: 50)

    let upgraded = try CueStore(location: .isolated(fixture.directory))
    let converted = try #require(try await upgraded.card(card.id))
    #expect(converted.body == "上\n---\n中 ---split--- 夹着\n---\n下" && converted.modifiedAt > before)
    #expect(try await upgraded.card(plain.id)?.modifiedAt == untouched)
    #expect(try await upgraded.trashedCards().map(\.body) == ["甲\n---\n乙"])
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
