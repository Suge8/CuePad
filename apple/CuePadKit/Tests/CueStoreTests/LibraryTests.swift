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

  // MARK: 卡片

  // MARK: 任务

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

  @Test func reopeningTheFileKeepsData() async throws {
    let card = try await store.createCard(in: nil, body: "persisted")
    let reopened = try CueStore(url: fixture.url)
    #expect(try await reopened.card(card.id)?.body == "persisted")
  }

  /// 把新建的库退回结构 32：撤掉 33（验收标记）。更早结构的升级测试先逐级撤到 29，再撤自己那一步。
  static let undoSchema33 = "ALTER TABLE cueMessages DROP COLUMN acceptance;"
  /// 退回结构 31：再撤掉 32（Cue）。
  static let undoSchema32 = undoSchema33 + """
    DROP TRIGGER cards_cueFollows_insert; DROP TRIGGER cards_cueFollows_update;
    DROP TABLE cueMessages; DROP TABLE cueLines; DROP TABLE cueProfile; DROP TABLE cueSummaries;
    ALTER TABLE cards DROP COLUMN cueFollows; ALTER TABLE deliveryRequests DROP COLUMN origin;
    DROP INDEX sendRecords_deliveryID; ALTER TABLE sendRecords DROP COLUMN deliveryID; ALTER TABLE sendRecords DROP COLUMN origin;
    """
  /// 退回结构 30：再撤掉 31（会话记录与历史索引记 Agent 的两列）。
  static let undoSchema31 = undoSchema32 + "ALTER TABLE piSessionStates DROP COLUMN agent; ALTER TABLE piSessions DROP COLUMN agent;"
  /// 退回结构 29：再撤掉 30（订阅额度）。
  static let undoSchema30 = undoSchema31 + "DROP TABLE accountQuotas;"

  /// 结构 32 的库升到 33：已有的消息原样都在（都不是验收），之后写的验收带着标记，答"收下"完成任务。
  @Test func schema32LibraryUpgradesForAcceptance() async throws {
    let task = try await store.createTask("发布", in: nil)
    let said = try await store.addCueMessage(.cue, text: "开工了")
    try RawDB(fixture.url).exec(Self.undoSchema33 + "PRAGMA user_version = 32;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.cueMessages().map { [$0.id: $0.isAcceptance] } == [[said.id: false]])
    let asked = try await upgraded.askToAccept(task.id, evidence: "- 测试全过").message
    try await upgraded.answerCueMessage(asked.id, answer: CueAcceptance.accept)
    #expect(try await upgraded.card(task.id)?.status == .done)
  }

  /// 结构 31 的库升到 32：卡片与投送请求原样都在（没有人跟进、请求来自你），顶层任务能交给 Cue 跟进，Cue 的对话可写。
  @Test func schema31LibraryUpgradesForCue() async throws {
    let task = try await store.createTask("发布", in: nil)
    try await store.requestDelivery("hi", to: SendTarget(kind: .piSession, name: "s", ref: "s1"), on: "mac")
    try RawDB(fixture.url).exec(Self.undoSchema32 + "PRAGMA user_version = 31;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.card(task.id)?.cueFollows == false)
    #expect(try await upgraded.deliveryRequests().map(\.origin) == [nil])
    #expect(try await upgraded.setCueFollows(task.id, true).cueFollows)
    #expect(try await upgraded.addCueMessage(.cue, text: "开工了").author == .known(.cue))
  }

  /// 结构 17 的库（会话记录还没有上下文余量与命令清单两列、没有预览表、对话里只有工具个数）就地升级，已有的会话记录不丢，
  /// 新列可写，预览可用；会话文件的检查点作废（下次从头读，补出旧对话的工具活动）。
  @Test func schema17LibraryUpgradesInPlaceAndKeepsSessionRecords() async throws {
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .settled, title: "旧会话")
    try await store.upsertPiSession(IndexedSession(id: "s1", path: "/s/s1.jsonl", cwd: "/w", lastActivityAt: .now), checkpoint: Data([1]), host: "mac")
    try RawDB(fixture.url).exec(Self.undoSchema30 + 
      """
      ALTER TABLE piSessionStates DROP COLUMN context; ALTER TABLE piSessionStates DROP COLUMN commands; DROP TABLE previews; DROP TABLE syncSent;
      ALTER TABLE piMessages DROP COLUMN tools; ALTER TABLE piMessages ADD COLUMN toolCount INTEGER NOT NULL DEFAULT 0;
      DROP INDEX piSessionStates_sessionID; DROP INDEX cards_deletedAt; DROP INDEX cards_todoAt; DROP INDEX cards_piSessionID; PRAGMA user_version = 17;
      """)

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.piCheckpoint(of: "s1") == nil)
    #expect(try await upgraded.allPiSessionStates().map(\.title) == ["旧会话"])
    try await PiStateRecorder(store: upgraded, hostID: "mac").update(
      sessionID: "s1", state: .settled, context: PiContextUsage(tokens: 1, window: 2))
    #expect(try await upgraded.allPiSessionStates().first?.context == PiContextUsage(tokens: 1, window: 2))
    #expect(try await upgraded.previews(of: "s1").isEmpty)
  }

  /// 结构 22 的库里已存的对话是旧的工具计数口径：升到 23 时会话文件的检查点作废，下次从头读。
  @Test func schema22LibraryDropsSessionCheckpoints() async throws {
    try await store.upsertPiSession(IndexedSession(id: "s1", path: "/s/s1.jsonl", cwd: "/w", lastActivityAt: .now), checkpoint: Data([1]), host: "mac")
    try RawDB(fixture.url).exec(Self.undoSchema30 + "DROP TABLE syncSent; PRAGMA user_version = 22;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.piCheckpoint(of: "s1") == nil)
  }

  /// 结构 23 的库里可能已有第 3 级的任务（旧规则允许）：升到 25 时改挂到上级的上级并带新的修改时间（才会同步出去）。
  @Test func schema23LibraryLiftsThirdLevelTasks() async throws {
    let top = try await store.createTask("上线", in: nil)
    let sub = try await store.createTask("备份", under: top.id)
    let deep = try await store.createTask("导出", in: nil)
    let before = try #require(try await store.card(deep.id)).modifiedAt
    try RawDB(fixture.url).exec(Self.undoSchema30 + "UPDATE cards SET parentID = '\(sub.id.uuidString.lowercased())' WHERE id = '\(deep.id.uuidString.lowercased())'; DROP TABLE syncSent; PRAGMA user_version = 23;")

    let upgraded = try CueStore(url: fixture.url)
    let lifted = try #require(try await upgraded.card(deep.id))
    #expect(lifted.parentID == top.id && lifted.modifiedAt > before)
    #expect(try await upgraded.card(sub.id)?.parentID == top.id)
  }

  /// 结构 26 的库里任务的正文可能带一句说明（第二行起）：升到 27 时拆成任务的草稿（不带会话），任务只留标题，带新的修改时间；
  /// 任务已有草稿的并进它末尾，不另立一条。
  @Test func schema26LibrarySplitsTaskNotesIntoPrompts() async throws {
    let task = try await store.createTask("修乱序", in: nil)
    let first = try await store.createCard(body: "先复现", under: task.id)
    try await store.linkCard(task.id, toSession: "s1")
    let before = try #require(try await store.card(task.id)).modifiedAt
    try RawDB(fixture.url).exec(Self.undoSchema30 + "UPDATE cards SET body = '修乱序\n第 6 位重连后会排到最前' WHERE id = '\(task.id.uuidString.lowercased())'; PRAGMA user_version = 26;")

    let upgraded = try CueStore(url: fixture.url)
    let upgradedTask = try #require(try await upgraded.card(task.id))
    #expect(upgradedTask.body == "修乱序" && upgradedTask.modifiedAt > before && upgradedTask.piSessionID == "s1")
    let prompts = try await upgraded.children(of: task.id)
    #expect(prompts.map(\.id) == [first.id] && prompts[0].body == "先复现\n\n第 6 位重连后会排到最前")
    #expect(prompts[0].piSessionID == nil && !prompts[0].isTask && prompts[0].modifiedAt > before)
  }

  /// 结构 27 的库里有步骤的任务下可能挂着提示词、记着会话，步骤下也可能有好几条提示词：升到 28 时有步骤的任务的提示词移到第一个没完成的步骤、
  /// 会话也交给它（它已有会话的丢弃上级的），一个叶子的多条提示词按顺序并成一条，带新的修改时间；发送记录不动。
  @Test func schema27LibraryPutsDraftsAndSessionsOnLeaves() async throws {
    let top = try await store.createTask("修乱序", in: nil)
    let done = try await store.createTask("复现", under: top.id)
    let open = try await store.createTask("改排序", under: top.id)
    try await store.setStatus(done.id, .done)
    let ideas = [
      try await store.createCard(in: nil, body: "任务自己的"), try await store.createCard(in: nil, body: "复现的"),
      try await store.createCard(in: nil, body: "改排序的第一条"), try await store.createCard(in: nil, body: "改排序的第二条"),
    ]
    let pins: [(Card, Card, String)] = [(ideas[0], top, "a"), (ideas[1], done, "a"), (ideas[2], open, "b"), (ideas[3], open, "c")]
    let sessions = [(top, "s1"), (open, "s2")]
    let sql = pins.map { "UPDATE cards SET parentID = '\($1.id.uuidString.lowercased())', sortKey = '\($2)' WHERE id = '\($0.id.uuidString.lowercased())';" }.joined()
      + sessions.map { "UPDATE cards SET piSessionID = '\($1)' WHERE id = '\($0.id.uuidString.lowercased())';" }.joined()
    let before = try #require(try await store.card(ideas[0].id)).modifiedAt
    try RawDB(fixture.url).exec(Self.undoSchema30 + sql + "PRAGMA user_version = 27;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.children(of: top.id).map(\.id) == [done.id, open.id])
    #expect(try await upgraded.children(of: done.id).map(\.id) == [ideas[1].id])
    let merged = try await upgraded.children(of: open.id)
    #expect(merged.map(\.id) == [ideas[0].id] && merged[0].modifiedAt > before)
    #expect(merged[0].body == "任务自己的\n\n改排序的第一条\n\n改排序的第二条")
    #expect(try await upgraded.card(top.id)?.piSessionID == nil)
    #expect(try await upgraded.card(done.id)?.piSessionID == nil)
    #expect(try await upgraded.card(open.id)?.piSessionID == "s2")
  }

  /// 结构 25 的库里已经发出去的提示词（记着交给的会话、没有在路上或失败的请求）升到 26 时删掉，任务记下的会话与发送记录留着；
  /// 资料、没发的、没送到的、不挂在任务下的灵感不动（之后升到 28 时，一个叶子上没发的与没送到的并成一条）。
  @Test func schema25LibraryDropsDeliveredPrompts() async throws {
    let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")
    let task = try await store.createTask("修乱序", in: nil)
    let ideas = [
      try await store.createCard(in: nil, body: "先复现"), try await store.createCard(in: nil, body: "常用说明"),
      try await store.createCard(in: nil, body: "还没发"), try await store.createCard(in: nil, body: "没送到"),
    ]
    let (delivered, resource, unsent, failed) = (ideas[0], ideas[1], ideas[2], ideas[3])
    let loose = try await store.createCard(in: nil, body: "散放的灵感")
    try await store.updateCard(resource.id) { $0.isPinned = true }
    try await store.linkCard(task.id, toSession: "s1")
    try await store.recordSend(delivered.body, to: atlas, card: delivered.id)
    try await store.linkCard(resource.id, toSession: "s1")
    try await store.linkCard(loose.id, toSession: "s1")
    let request = try await store.requestDelivery(failed.body, to: atlas, on: "mac", card: failed.id)
    try await store.linkCard(failed.id, toSession: "s1")
    // 旧版本允许的结构：同一个任务下有好几条提示词
    let parents = zip(ideas, ["a", "b", "c", "d"]).map {
      "UPDATE cards SET parentID = '\(task.id.uuidString.lowercased())', sortKey = '\($1)' WHERE id = '\($0.id.uuidString.lowercased())';"
    }.joined()
    try RawDB(fixture.url).exec(Self.undoSchema30 + parents + "UPDATE deliveryRequests SET status = 'failed' WHERE id = '\(request.id.uuidString.lowercased())'; PRAGMA user_version = 25;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.children(of: task.id).map(\.id) == [resource.id, unsent.id])
    #expect(try await upgraded.card(unsent.id)?.body == "还没发\n\n没送到")
    #expect(try await upgraded.card(loose.id) != nil)
    #expect(try await upgraded.card(task.id)?.piSessionID == "s1")
    #expect(try await upgraded.trashedCards().isEmpty)
    #expect(try await upgraded.archived().isEmpty)
    #expect(try await upgraded.sendRecords().map(\.cardID) == [nil])
  }

  /// 更新版本建的库与更早版本建的库（不再升级旧结构）都拒绝打开，不在错位的表结构上读写。
  @Test(arguments: [
    (CueStore.supportedSchemaVersions.upperBound + 1, CueStoreError.unsupportedSchemaVersion(CueStore.supportedSchemaVersions.upperBound + 1)),
    (16, .schemaTooOld(16)),
  ])
  func libraryFromAnotherSchemaVersionIsRefused(version: Int, error: CueStoreError) throws {
    let url = fixture.directory.appending(path: "other/cuepad.db")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try RawDB(url).exec("CREATE TABLE cards (id TEXT PRIMARY KEY NOT NULL) STRICT; PRAGMA user_version = \(version);")
    #expect(throws: error) { try CueStore(url: url) }
  }
}
