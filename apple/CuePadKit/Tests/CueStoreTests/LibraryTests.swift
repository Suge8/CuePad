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

  /// 项目进回收站时它的卡随项目隐藏（不逐卡记）；恢复、永久删除项目都不带走早先单独删的卡：恢复后它们仍在回收站，
  /// 项目还在回收站时恢复其中一张落到默认项目，项目永久删除后另一张挪进默认项目、仍在回收站。
  @Test func trashRestoreAndPurgeOfAProjectNeverTakeCardsTrashedOnTheirOwn() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let kept = try await store.createCard(in: p.id, body: "kept")
    let alone = [try await store.createCard(in: p.id, body: "trashed earlier"), try await store.createCard(in: p.id, body: "also trashed")]
    for card in alone { try await store.trashCard(card.id) }

    try await store.trashProject(p.id)
    #expect(try await store.cards(in: p.id).isEmpty)
    #expect(try await store.trashedProjects().map(\.id) == [p.id])
    #expect(try await store.card(kept.id)?.deletedAt == nil)
    try await store.restoreProject(p.id)
    #expect(bodies(try await store.cards(in: p.id)) == ["kept"])
    #expect(Set(try await store.trashedCards().map(\.id)) == Set(alone.map(\.id)))

    try await store.trashProject(p.id)
    try await store.restoreCard(alone[0].id)
    #expect(try await store.cards(in: Project.defaultID).map(\.id) == [alone[0].id])

    try await store.purgeProject(p.id)
    #expect(try await store.card(kept.id) == nil)
    #expect(try await store.project(p.id) == nil)
    let survivor = try await store.card(alone[1].id)
    #expect(survivor?.projectID == Project.defaultID && survivor?.deletedAt != nil)
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
    #expect(try await store.projects().map(\.id) == [live.id, Project.defaultID])
    #expect(try await store.trashedProjects().isEmpty)
  }

  // MARK: 结构版本

}
