import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct MappingTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func populate() async throws -> (card: Card, hash: String) {
    let hash = try store.files.store(pngData(width: 2, height: 2))
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "hello ![](cuepad://img/\(hash))")
    try await store.updateCard(card.id) {
      $0.isPinned = true
      $0.variableValues = ["k": "v"]
    }
    try await store.recordSend("x", to: SendTarget(kind: .piSession, name: "n", ref: "r"), card: card.id)
    try await PiStateRecorder(store: store, hostID: "mac").update(
      sessionID: "s1", state: .waitingForUser, detail: "确认？", title: "t", directory: "/work/p", projectID: project.id,
      context: PiContextUsage(tokens: 1_000, window: 200_000), commands: [PiSlashCommand(name: "compact", summary: "压缩", source: .known(.builtin))])
    try await store.requestDelivery("deliver me", to: SendTarget(kind: .piSession, name: "n", ref: "r"), on: "mac", card: card.id)
    try await store.setDirectory("/work/p", for: project.id)
    try await store.publishDirectoryBindings(host: "mac", hostName: "Studio")
    try await store.writePiTranscript(PiTranscript(
      sessionID: "s1", messages: [PiChatMessage(sessionID: "s1", entryID: "e1", seq: 1, role: .user, text: "修好登录", at: .now)],
      recap: PiRecap(pendingPrompt: "修好登录")))
    let page = rig.fixture.directory.appending(path: "demo.html")
    try Data("<h1>登录页</h1>".utf8).write(to: page)
    _ = try await store.addPreviews(filesAt: [page], title: "登录页", sessionID: "s1")
    try await store.recordQuota(
      QuotaReport(provider: "anthropic", windows: [QuotaWindow(seconds: 18_000, used: 0.2, resetsAt: .now)], complete: true), host: "mac")
    try await store.addCueMessage(.cue, text: "要发布吗？", ask: .release, urgent: true, task: card.id)
    try await store.noteCueLine("发布前先跑检查", source: .you, pinned: true, remindAt: .now.addingTimeInterval(60))
    try await store.updateCueProfile { $0.hostID = "mac" }
    try await store.setCueState(.tool, detail: "建任务 · 修好登录页")
    try await store.recordMacPresence(host: "mac") { true }
    try await store.recordMacAgents(host: "mac", [MacAgent(kind: .pi, model: nil, models: [])])
    return (card, hash)
  }

  @Test func everySyncedTableRoundTripsThroughCKRecord() async throws {
    _ = try await populate()
    let keys = try await store.pendingSync().saves
    #expect(Set(keys.map(\.table)) == Set(Table.synced))  // 每张同步表都有记录

    for key in keys {
      let row = try #require(try await store.syncRow(recordName: key.id))
      let record = RecordMapper.record(from: row, zoneID: testZone)
      #expect(record.recordType == key.table.rawValue)
      #expect(record.recordID.recordName == key.id)
      #expect(record.recordID.zoneID == testZone)
      #expect(RecordMapper.row(from: record) == row)
    }
  }

  @Test func userContentIsEncryptedAndStructureIsPlain() async throws {
    let (card, _) = try await populate()
    let row = try #require(try await store.syncRow(recordName: card.id.uuidString.lowercased()))
    let record = RecordMapper.record(from: row, zoneID: testZone)

    #expect(record.encryptedValues["body"] as? String == card.body)
    #expect(record["body"] == nil)
    #expect(record.encryptedValues["variableValues"] as? String != nil)
    #expect(record["sortKey"] as? String == card.sortKey)
    #expect(record["modifiedAt"] as? Int64 != nil && record.encryptedValues["modifiedAt"] == nil)

    let names = ["projects": "name", "sendRecords": "content"]
    for key in try await store.pendingSync().saves {
      guard let field = names[key.table.rawValue] else { continue }
      let other = RecordMapper.record(from: try #require(try await store.syncRow(recordName: key.id)), zoneID: testZone)
      #expect(other.encryptedValues[field] != nil && other[field] == nil)
    }
  }

  @Test func nilFieldsAreAbsentFromTheRecord() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let record = RecordMapper.record(from: try #require(try await store.syncRow(recordName: project.id.uuidString.lowercased())), zoneID: testZone)
    #expect(record["icon"] == nil && record["intro"] == nil && record["deletedAt"] == nil)
  }

  @Test func unknownEnumValuesAreKeptVerbatimNotCoercedToKnownOnes() async throws {
    let send = remoteRecord(.sendRecords, sendFields(kind: "carrierPigeon", modifiedAt: 5_000))

    await rig.coordinator.handle(.fetched(modifications: [send], deletions: []))

    let records = try await store.sendRecords()
    #expect(records.map(\.targetKind) == [.unknown("carrierPigeon")])
    #expect(try await store.sendTargets().isEmpty)  // 没有关联卡片，不进目标列表

    // 原样推回：其他字段被编辑后，未知值不变
    try await store.recordSend("x", to: SendTarget(kind: .known(.piSession), name: "a"))
    let pushedSend = try #require(await rig.coordinator.record(for: send.recordID))
    #expect(pushedSend["targetKind"] as? String == "carrierPigeon")
  }

  @Test func unknownRecordTypesAreSkippedAndReported() async throws {
    let alien = CKRecord(recordType: "widgets", recordID: CKRecord.ID(recordName: UUID().uuidString.lowercased(), zoneID: testZone))
    alien["size"] = 3 as Int64

    await rig.coordinator.handle(.fetched(modifications: [alien], deletions: [(alien.recordID, "widgets")]))

    #expect(try RawDB(rig.fixture.url).count("syncRecords") == 0)
    let issues = await rig.coordinator.issues
    #expect(issues.contains { $0.message.contains("widgets") })
  }
}
