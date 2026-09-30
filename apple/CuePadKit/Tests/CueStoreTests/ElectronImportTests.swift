import CueStore
import CryptoKit
import Foundation
import Testing

/// 旧库 fixture：schema 与 Electron 版迁移 001–005 的最终状态一致。
private let legacySchema = """
  CREATE TABLE projects (
    id INTEGER PRIMARY KEY, name TEXT, icon TEXT, color TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0, is_pinned INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER, delete_batch_id TEXT, delete_source TEXT, delete_source_id INTEGER,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  CREATE TABLE cards (
    id INTEGER PRIMARY KEY, project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
    title TEXT, body TEXT, sort_order INTEGER NOT NULL DEFAULT 0,
    is_favorite INTEGER NOT NULL DEFAULT 0, numbering TEXT NOT NULL DEFAULT 'none',
    deleted_at INTEGER, delete_batch_id TEXT, delete_source TEXT, delete_source_id INTEGER,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  CREATE TABLE tags (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, color TEXT, sort_order INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER, delete_batch_id TEXT, delete_source TEXT, delete_source_id INTEGER,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  CREATE TABLE card_tags (
    card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL, PRIMARY KEY (card_id, tag_id));
  CREATE TABLE tasks (
    id INTEGER PRIMARY KEY, content TEXT NOT NULL,
    project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
    sort_order INTEGER NOT NULL DEFAULT 0, completed_at INTEGER,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);

  -- 项目：Career 排在 Flow 前（sort_order 1 < 2）；Flow 置顶；Gone 已删除（批次 b1）
  INSERT INTO projects VALUES (1,'Flow','target','#4f8ce8',2,1,NULL,NULL,NULL,NULL,1000,2000);
  INSERT INTO projects VALUES (2,'Career','book','#e2679c',1,0,NULL,NULL,NULL,NULL,1100,2100);
  INSERT INTO projects VALUES (3,NULL,NULL,'#999999',3,0,5000,'b1','project',3,1200,5000);

  -- 卡片
  INSERT INTO cards VALUES (10,1,'Todo','line one',1,1,'decimal',NULL,NULL,NULL,NULL,3000,4000);
  INSERT INTO cards VALUES (11,1,'Only title','',2,0,'none',NULL,NULL,NULL,NULL,3100,4100);
  INSERT INTO cards VALUES (12,NULL,NULL,'inbox body',0,0,'alpha',NULL,NULL,NULL,NULL,3200,4200);
  INSERT INTO cards VALUES (13,3,NULL,'goes with Gone',1,0,'none',5000,'b1','project',3,3300,5000);
  INSERT INTO cards VALUES (14,3,NULL,'trashed before Gone',2,0,'none',4500,'b0','card',14,3400,4500);
  INSERT INTO cards VALUES (15,2,NULL,'trashed alone',1,0,'none',4600,'b2','card',15,3500,4600);

  INSERT INTO tags VALUES (1,'idea','#fa0',0,NULL,NULL,NULL,NULL,3600,3600);
  INSERT INTO card_tags VALUES (10,1,3700);

  INSERT INTO tasks VALUES (20,'second',NULL,2,NULL,6000,6000);
  INSERT INTO tasks VALUES (21,'first',1,1,NULL,6100,6100);
  INSERT INTO tasks VALUES (22,'done',NULL,3,7000,6200,7000);

  INSERT INTO app_settings VALUES ('theme','"dark"',1,2);
  INSERT INTO app_settings VALUES ('globalShortcut','"Alt+KeyZ"',1,2);
  """

private func makeLegacyDatabase() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "cuepad-legacy-\(UUID().uuidString).db")
  try RawDB(url).exec(legacySchema)
  return url
}

private func digest(_ url: URL) throws -> String {
  SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

@Suite struct ElectronImportTests {
  let legacy: URL
  let fixture: Fixture
  var store: CueStore { fixture.store }

  init() throws {
    legacy = try makeLegacyDatabase()
    fixture = try Fixture()
  }

  @Test func mapsLegacyRowsToTheNewModel() async throws {
    let report = try await store.importElectronLibrary(from: legacy)
    #expect(report.found == ImportCounts(projects: 3, cards: 6, tasks: 3))
    #expect(report.inserted == report.found)
    #expect(report.legacySettings == ["theme": "\"dark\"", "globalShortcut": "\"Alt+KeyZ\""])

    // 项目：按旧 sort_order 排序，置顶保留，NULL 名称变空串，删除时间保留
    let active = try await store.projects()
    let trashed = try await store.trashedProjects()
    #expect(active.map(\.name) == ["Career", "Flow"])
    #expect(active.map(\.isPinned) == [false, true])
    #expect(active.last?.icon == "target" && active.last?.color == "#4f8ce8")
    #expect(trashed.map(\.name) == [""])
    sameInstant(trashed.first?.deletedAt, Date(timeIntervalSince1970: 5))
    sameInstant(active.last?.createdAt, Date(timeIntervalSince1970: 1))

    // 卡片：标题并入正文首行；随项目删除的卡不再单独记 deletedAt；单独删除的保留
    let flow = active.last!
    let career = active.first!
    let flowCards = try await store.cards(in: flow.id)
    #expect(bodies(flowCards) == ["Todo\n\nline one", "Only title"])  // 保持旧 sort_order
    #expect(flowCards.first?.numbering == .decimal && flowCards.first?.isPinned == true)
    let inbox = try await store.cards(in: nil)
    #expect(bodies(inbox) == ["inbox body"] && inbox.first?.numbering == .alpha)

    let trashedCards = try await store.trashedCards()
    #expect(Set(bodies(trashedCards)) == ["trashed before Gone", "trashed alone"])
    let byBody = Dictionary(uniqueKeysWithValues: trashedCards.map { ($0.body, $0) })
    sameInstant(byBody["trashed before Gone"]?.deletedAt, Date(timeIntervalSince1970: 4.5))
    sameInstant(byBody["trashed alone"]?.deletedAt, Date(timeIntervalSince1970: 4.6))
    #expect(byBody["trashed alone"]?.projectID == career.id)

    let gone = trashed[0]
    let followsProject = try RawDB(fixture.url).rows(
      "SELECT deletedAt, projectID FROM cards WHERE body = 'goes with Gone'")
    #expect(followsProject == [["NULL", gone.id.uuidString.lowercased()]])

    // 任务（标签不导入：产品不做标签）
    let open = try await store.tasks()
    #expect(open.map(\.content) == ["first", "second"])
    #expect(open.first?.projectID == flow.id)
    let done = try await store.completedTasks()
    #expect(done.map(\.content) == ["done"])
    sameInstant(done.first?.completedAt, Date(timeIntervalSince1970: 7))
  }

  @Test func importIsIdempotentAndNeverOverwritesLaterEdits() async throws {
    _ = try await store.importElectronLibrary(from: legacy)
    let card = try await store.cards(in: nil)[0]
    try await store.updateCard(card.id) { $0.body = "edited in Swift" }
    let raw = RawDB(fixture.url)
    let before = try ["projects", "cards", "tasks"].map(raw.count)

    let again = try await store.importElectronLibrary(from: legacy)

    #expect(again.found.cards == 6 && again.inserted == ImportCounts())
    #expect(try ["projects", "cards", "tasks"].map(raw.count) == before)
    #expect(try await store.card(card.id)?.body == "edited in Swift")
  }

  @Test func sourceFileIsNeverModified() async throws {
    let before = try digest(legacy)
    _ = try await store.importElectronLibrary(from: legacy)
    #expect(try digest(legacy) == before)
  }

  @Test func importedRowsAreSearchable() async throws {
    _ = try await store.importElectronLibrary(from: legacy)
    #expect(try await store.search("inbox").cards.count == 1)
    #expect(try await store.search("Career").projects.count == 1)
  }
}
