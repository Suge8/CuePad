import CueStore
import Foundation
import Testing

@testable import CueStore

@Suite struct LibraryTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  // MARK: 排序

  @Test func projectsAppendAtEndAndMoveAfterNeighbor() async throws {
    _ = try await store.createProject(name: "A", color: "#111")
    let b = try await store.createProject(name: "B", color: "#222")
    let c = try await store.createProject(name: "C", color: "#333")
    func names() async throws -> [String] { try await store.projects().map(\.name) }
    #expect(try await names() == ["A", "B", "C"])

    try await store.moveProject(c.id, after: nil)
    #expect(try await names() == ["C", "A", "B"])

    try await store.moveProject(c.id, after: b.id)
    #expect(try await names() == ["A", "B", "C"])
  }

  @Test func newCardGoesOnTopAndMoveOnlyTouchesTheMovedCard() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let c1 = try await store.createCard(in: p.id, body: "1")
    let c2 = try await store.createCard(in: p.id, body: "2")
    let c3 = try await store.createCard(in: p.id, body: "3")
    #expect(bodies(try await store.cards(in: p.id)) == ["3", "2", "1"])

    let before = try await store.card(c2.id)
    try await store.moveCard(c3.id, to: p.id, after: c1.id)
    #expect(bodies(try await store.cards(in: p.id)) == ["2", "1", "3"])
    #expect(try await store.card(c2.id) == before)
  }

  @Test func moveCardToInbox() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: p.id, body: "x")
    try await store.moveCard(card.id, to: nil, after: nil)
    #expect(bodies(try await store.cards(in: nil)) == ["x"])
    #expect(try await store.cards(in: p.id).isEmpty)
  }

  @Test func moveSurvivesEqualSortKeysFromConcurrentDevices() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    for body in ["1", "2", "3"] { _ = try await store.createCard(in: p.id, body: body) }
    try RawDB(fixture.url).exec("UPDATE cards SET sortKey = 'V'")
    let start = try await store.cards(in: p.id)

    try await store.moveCard(start[0].id, to: p.id, after: start[1].id)

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

  // MARK: 卡片、标签、附件

  @Test func cardFieldsRoundTrip() async throws {
    let card = try await store.createCard(in: nil, body: "hi {{name}}")
    try await store.updateCard(card.id) {
      $0.numbering = .cjk
      $0.isFavorite = true
      $0.variableValues = ["name": "Pi"]
    }
    let row = try await store.card(card.id)
    #expect(row?.numbering == .cjk)
    #expect(row?.variableValues == ["name": "Pi"])
    #expect(try await store.favoriteCards().map(\.id) == [card.id])
  }

  @Test func tagsAreSharedByNameAndLinkedOncePerCard() async throws {
    let one = try await store.createCard(in: nil, body: "1")
    let two = try await store.createCard(in: nil, body: "2")
    let first = try await store.addTag("idea", to: one.id)
    _ = try await store.addTag("idea", to: one.id)
    let second = try await store.addTag("idea", to: two.id)
    #expect(first.id == second.id)
    #expect(try RawDB(fixture.url).count("cardTags") == 2)

    try await store.removeTag(first.id, from: one.id)
    #expect(try await store.tags(of: one.id).isEmpty)
    #expect(try await store.tags(of: two.id).map(\.name) == ["idea"])
  }

  @Test func purgingCardRemovesItsTagLinks() async throws {
    let card = try await store.createCard(in: nil, body: "1")
    try await store.addTag("idea", to: card.id)
    try await store.purgeCard(card.id)
    #expect(try RawDB(fixture.url).count("cardTags") == 0)
  }

  @Test func attachmentsDedupeByContentHash() async throws {
    let a = try await store.registerAttachment(hash: "abc123", byteCount: 10, format: "png")
    let b = try await store.registerAttachment(hash: "abc123", byteCount: 10, format: "png")
    let c = try await store.registerAttachment(hash: "def456", byteCount: 20, format: "jpeg")
    #expect(a.id == b.id && a.id != c.id)
    #expect(try RawDB(fixture.url).count("attachments") == 2)
  }

  // MARK: 任务

  @Test func tasksStackNewestOnTopAndCompletedLeaveTheActiveList() async throws {
    let a = try await store.createTask("a")
    let b = try await store.createTask("b")
    let c = try await store.createTask("c")
    func active() async throws -> [String] { try await store.tasks().map(\.content) }
    #expect(try await active() == ["c", "b", "a"])

    try await store.moveTask(c.id, after: a.id)
    #expect(try await active() == ["b", "a", "c"])

    try await store.updateTask(b.id) { $0.completedAt = Date() }
    #expect(try await active() == ["a", "c"])
    #expect(try await store.completedTasks().map(\.content) == ["b"])
  }

  @Test func blankTaskContentIsRejected() async throws {
    await #expect(throws: CueStoreError.blankTaskContent) {
      try await store.createTask("   ")
    }
    let task = try await store.createTask("real")
    await #expect(throws: CueStoreError.blankTaskContent) {
      try await store.updateTask(task.id) { $0.content = "" }
    }
  }

  @Test func deletingProjectKeepsItsTasksGlobal() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let task = try await store.createTask("t", in: p.id)
    try await store.trashProject(p.id)
    try await store.purgeProject(p.id)
    #expect(try await store.tasks().map(\.id) == [task.id])
    #expect(try await store.tasks().first?.projectID == nil)
  }

  // MARK: 发送记录与 Pi 会话索引

  @Test func sendRecordKeepsContentSnapshotAfterCardIsPurged() async throws {
    let card = try await store.createCard(in: nil, body: "prompt v1")
    try await store.recordSend(
      "prompt v1", to: SendTarget(kind: .app, name: "Ghostty", ref: "com.mitchellh.ghostty"),
      card: card.id)
    try await store.updateCard(card.id) { $0.body = "prompt v2" }
    try await store.purgeCard(card.id)

    let records = try await store.sendRecords()
    #expect(records.map(\.content) == ["prompt v1"])
    #expect(records.first?.cardID == nil)
    #expect(records.first?.targetName == "Ghostty")
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
}
