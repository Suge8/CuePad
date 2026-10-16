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

  /// 把新建的库退回结构 48：撤掉 49（Cue 的允许清单）。更早结构的升级测试从这里逐级往回撤。
  static let undoSchema49 = "ALTER TABLE cueProfile DROP COLUMN allows;"
  /// 退回结构 47：再撤掉 48（每台 Mac 上能用的 Agent）。
  static let undoSchema48 = undoSchema49 + "DROP TABLE macAgents;"
  /// 退回结构 46：再撤掉 47（Cue 此刻的状态只记在跑的那一行）。
  static let undoSchema47 = undoSchema48 + "ALTER TABLE cueState DROP COLUMN round; ALTER TABLE cueState ADD COLUMN pendingTools TEXT;"
  /// 退回结构 44：46（删掉自动建的外壳任务）只动数据，不用撤；再撤掉 45（Cue 的一轮的经过）。
  static let undoSchema45 = undoSchema47 + "ALTER TABLE cueMessages DROP COLUMN tools; ALTER TABLE cueState DROP COLUMN pendingTools;"
  /// 退回结构 43：再撤掉 44（会话记录上这一轮已做完的工具活动）。
  static let undoSchema44 = undoSchema45 + "ALTER TABLE piSessionStates DROP COLUMN pendingTools;"
  /// 退回结构 42：再撤掉 43（模型与命令的目录记录）。
  static let undoSchema43 = undoSchema44 + """
    DROP INDEX piSessionStates_catalogID; ALTER TABLE piSessionStates DROP COLUMN catalogID; DROP TABLE agentCatalogs;
    ALTER TABLE piSessionStates ADD COLUMN models TEXT; ALTER TABLE piSessionStates ADD COLUMN commands TEXT;
    """
  /// 退回结构 41：42（同步元数据换形）从哪种形状都能重建，不用撤。
  static let undoSchema42 = undoSchema43
  /// 退回结构 40：再撤掉 41（每台 Mac 的在线记录）。
  static let undoSchema41 = undoSchema42 + "DROP TABLE macPresence;"
  /// 退回结构 39：再撤掉 40（请求上记 Cue 已知道没送到，本机列）。
  static let undoSchema40 = undoSchema41 + "ALTER TABLE deliveryRequests DROP COLUMN cueToldAt;"
  /// 退回结构 38：再撤掉 39（卡片上的跟进标记下线；盖序号的触发器去掉它后重建，退回时留着新的也照样能升级）。
  static let undoSchema39 = undoSchema40 + "ALTER TABLE cards ADD COLUMN cueFollows INTEGER NOT NULL DEFAULT 0;"
  /// 退回结构 37：再撤掉 38（本机写入序号：计数器、各表的序号列与盖序号的触发器）。
  static let undoSchema38 = undoSchema39 + """
    DROP TRIGGER piSessionStates_writeSeq_insert; DROP TRIGGER piSessionStates_writeSeq_update;
    DROP TRIGGER cards_writeSeq_insert; DROP TRIGGER cards_writeSeq_update;
    DROP TRIGGER deliveryRequests_writeSeq_insert; DROP TRIGGER deliveryRequests_writeSeq_update; DROP TRIGGER piMessages_writeSeq_insert;
    ALTER TABLE piSessionStates DROP COLUMN writeSeq; ALTER TABLE cards DROP COLUMN writeSeq;
    ALTER TABLE deliveryRequests DROP COLUMN writeSeq; ALTER TABLE piMessages DROP COLUMN writeSeq; DROP TABLE writeCounter;
    """
  /// 退回结构 36：再撤掉 37（验收标记下线）。
  static let undoSchema37 = undoSchema38 + "ALTER TABLE cueMessages ADD COLUMN acceptance INTEGER NOT NULL DEFAULT 0;"
  /// 退回结构 35：再撤掉 36（本机的会话进程表）。
  static let undoSchema36 = undoSchema37 + "DROP TABLE piProcesses;"
  /// 退回结构 34：再撤掉 35（Cue 此刻在做什么）。
  static let undoSchema35 = undoSchema36 + "DROP TABLE cueState;"
  /// 退回结构 33：再撤掉 34（叶子以前用过的会话）。
  static let undoSchema34 = undoSchema35 + "DROP INDEX cards_formerSessionIDs; ALTER TABLE cards DROP COLUMN formerSessionIDs;"
  /// 退回结构 32：再撤掉 33（验收标记）。更早结构的升级测试先逐级撤到 29，再撤自己那一步。
  static let undoSchema33 = undoSchema34 + "ALTER TABLE cueMessages DROP COLUMN acceptance;"
  /// 退回结构 31：再撤掉 32（Cue）。
  static let undoSchema32 = undoSchema33 + """
    DROP TABLE cueMessages; DROP TABLE cueLines; DROP TABLE cueProfile; DROP TABLE cueSummaries;
    ALTER TABLE cards DROP COLUMN cueFollows; ALTER TABLE deliveryRequests DROP COLUMN origin;
    DROP INDEX sendRecords_deliveryID; ALTER TABLE sendRecords DROP COLUMN deliveryID; ALTER TABLE sendRecords DROP COLUMN origin;
    """
  /// 退回结构 30：再撤掉 31（会话记录与历史索引记 Agent 的两列）。
  static let undoSchema31 = undoSchema32 + "ALTER TABLE piSessionStates DROP COLUMN agent; ALTER TABLE piSessions DROP COLUMN agent;"
  /// 退回结构 29：再撤掉 30（订阅额度）。
  static let undoSchema30 = undoSchema31 + "DROP TABLE accountQuotas;"

  /// 结构 42 的库升到 43：会话记录原样都在（带着的模型与命令清单丢掉，在线会话由桥重连后写进目录记录），目录记录可写可读。
  @Test func schema42LibraryMovesModelListsOffSessionRecords() async throws {
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .settled, title: "旧会话")
    try RawDB(fixture.url).exec(Self.undoSchema43 + "UPDATE piSessionStates SET models = '[]', commands = '[]'; PRAGMA user_version = 42;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.allPiSessionStates().map(\.title) == ["旧会话"])
    let compact = PiSlashCommand(name: "compact", summary: nil, source: .known(.builtin))
    try await PiStateRecorder(store: upgraded, hostID: "mac").update(sessionID: "s1", state: .settled, directory: "/w", commands: [compact])
    let catalog = try #require(try await upgraded.allPiSessionStates().first?.catalogID)
    #expect(try await upgraded.agentCatalog(catalog)?.commands == [compact])
  }

  /// 结构 36 的库升到 37：还开着的旧验收是 Cue 已收尾的事——任务连同步骤完成，那条成了做完的结果；Cue 自拟选项的提问撤回，
  /// 不再等你、也不交给 Cue；答过的照原样留着。
  @Test func schema36LibraryUpgradesWithoutAcceptance() async throws {
    let task = try await store.createTask("发布", in: nil)
    let step = try await store.createTask("跑检查", under: task.id)
    let accept = try await store.addCueMessage(.cue, text: "「发布」做好了，收下吗？\n- 检查都过了", ask: .push, task: task.id)
    let custom = try await store.addCueMessage(.cue, text: "调研方案好了，照这个做吗？", ask: .push)
    let answered = try await store.addCueMessage(.cue, text: "要推送吗？", ask: .push)
    try await store.endCueQuestion(answered.id, .answered("允许一次"))
    try await store.markCueMessagesDelivered([answered.id])
    try RawDB(fixture.url).exec(Self.undoSchema37 + """
      UPDATE cueMessages SET acceptance = 1, choices = '["收下","再改改"]' WHERE id = '\(accept.id.uuidString.lowercased())';
      UPDATE cueMessages SET choices = '["照这个做","我再看看"]' WHERE id = '\(custom.id.uuidString.lowercased())';
      PRAGMA user_version = 36;
      """)

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.cueMessagesWaitingForYou().isEmpty)
    #expect(try await upgraded.cueMessagesToDeliver().isEmpty)
    #expect(try await upgraded.card(task.id)?.status == .done)
    #expect(try await upgraded.card(step.id)?.status == .done)
    let messages = Dictionary(uniqueKeysWithValues: try await upgraded.cueMessages().map { ($0.id, $0) })
    #expect(messages[accept.id]?.text == "「发布」做完了。\n- 检查都过了" && messages[accept.id]?.choices == nil)
    #expect(messages[custom.id]?.answeredAt != nil && messages[custom.id]?.answer == nil)
    #expect(messages[answered.id]?.answer == "允许一次")
  }

  /// 结构 31 的库升到 32 起：卡片与投送请求原样都在（请求来自你），Cue 的对话可写。
  @Test func schema31LibraryUpgradesForCue() async throws {
    let task = try await store.createTask("发布", in: nil)
    try await store.requestDelivery("hi", to: SendTarget(kind: .piSession, name: "s", ref: "s1"), on: "mac")
    try RawDB(fixture.url).exec(Self.undoSchema32 + "PRAGMA user_version = 31;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.card(task.id)?.heading == "发布")
    #expect(try await upgraded.deliveryRequests().map(\.origin) == [nil])
    #expect(try await upgraded.addCueMessage(.cue, text: "开工了").author == .known(.cue))
  }

  /// 结构 17 的库（会话记录还没有上下文余量与命令清单两列、没有预览表、对话里只有工具个数）就地升级，已有的会话记录不丢，
  /// 新列可写，预览可用；会话文件的检查点作废（下次从头读，补出旧对话的工具活动）。
  @Test func schema17LibraryUpgradesInPlaceAndKeepsSessionRecords() async throws {
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .settled, title: "旧会话")
    try await store.upsertPiSession(IndexedSession(id: "s1", path: "/s/s1.jsonl", cwd: "/w", lastActivityAt: .now), checkpoint: Data([1]), host: "mac")
    try RawDB(fixture.url).exec(Self.undoSchema30 + 
      """
      ALTER TABLE piSessionStates DROP COLUMN context; ALTER TABLE piSessionStates DROP COLUMN commands; DROP TABLE previews;
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
    try RawDB(fixture.url).exec(Self.undoSchema30 + "PRAGMA user_version = 22;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.piCheckpoint(of: "s1") == nil)
  }

  /// 结构 23 的库里可能已有第 3 级的任务（旧规则允许）：升到 25 时改挂到上级的上级并带新的修改时间（才会同步出去）。
  @Test func schema23LibraryLiftsThirdLevelTasks() async throws {
    let top = try await store.createTask("上线", in: nil)
    let sub = try await store.createTask("备份", under: top.id)
    let deep = try await store.createTask("导出", in: nil)
    let before = try #require(try await store.card(deep.id)).modifiedAt
    try RawDB(fixture.url).exec(Self.undoSchema30 + "UPDATE cards SET parentID = '\(sub.id.uuidString.lowercased())' WHERE id = '\(deep.id.uuidString.lowercased())'; PRAGMA user_version = 23;")

    let upgraded = try CueStore(url: fixture.url)
    let lifted = try #require(try await upgraded.card(deep.id))
    #expect(lifted.parentID == top.id && lifted.modifiedAt > before)
    #expect(try await upgraded.card(sub.id)?.parentID == top.id)
  }

  /// 结构 27 的库里有步骤的任务可能记着会话：升到 28 时交给第一个没完成的步骤（它已有会话的丢弃上级的）。
  @Test func schema27LibraryPutsSessionsOnLeaves() async throws {
    let top = try await store.createTask("修乱序", in: nil)
    let done = try await store.createTask("复现", under: top.id)
    let open = try await store.createTask("改排序", under: top.id)
    let other = try await store.createTask("发版", in: nil)
    let step = try await store.createTask("打包", under: other.id)
    try await store.setStatus(done.id, .done)
    let sessions = [(top, "s1"), (open, "s2"), (other, "s3")]
    let sql = sessions.map { "UPDATE cards SET piSessionID = '\($1)' WHERE id = '\($0.id.uuidString.lowercased())';" }.joined()
    try RawDB(fixture.url).exec(Self.undoSchema30 + sql + "PRAGMA user_version = 27;")

    let upgraded = try CueStore(url: fixture.url)
    #expect(try await upgraded.card(top.id)?.piSessionID == nil)
    #expect(try await upgraded.card(done.id)?.piSessionID == nil)
    #expect(try await upgraded.card(open.id)?.piSessionID == "s2")
    #expect(try await upgraded.card(other.id)?.piSessionID == nil)
    #expect(try await upgraded.card(step.id)?.piSessionID == "s3")
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
    try RawDB(fixture.url).exec(parents + "UPDATE cards SET piSessionID = 's1' WHERE id = '\(second.id.uuidString.lowercased())'; PRAGMA user_version = 49;")

    let upgraded = try CueStore(url: fixture.url)
    let folded = try #require(try await upgraded.card(task.id))
    #expect(folded.body == "修乱序\n\n先复现\n\n再改排序" && folded.piSessionID == "s1" && folded.modifiedAt > before)
    #expect(try await upgraded.children(of: task.id).map(\.id) == [resource.id])
    #expect(try await upgraded.card(first.id) == nil)
    #expect(try await upgraded.card(second.id) == nil)
    #expect(try await upgraded.trashedCards().map(\.id) == [trashed.id])
    #expect(try await upgraded.deliveryRequests().first { $0.id == request.id }?.cardID == task.id)
    #expect(try await upgraded.sendRecords().map(\.cardID) == [task.id])
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
    try RawDB(fixture.url).exec("PRAGMA user_version = 50;")

    let upgraded = try CueStore(url: fixture.url)
    let converted = try #require(try await upgraded.card(card.id))
    #expect(converted.body == "上\n---\n中 ---split--- 夹着\n---\n下" && converted.modifiedAt > before)
    #expect(try await upgraded.card(plain.id)?.modifiedAt == untouched)
    #expect(try await upgraded.trashedCards().map(\.body) == ["甲\n---\n乙"])
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
