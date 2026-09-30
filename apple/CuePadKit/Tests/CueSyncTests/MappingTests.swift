import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct MappingTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func populate() async throws -> (card: Card, hash: String) {
    let hash = String(repeating: "a", count: 64)
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "hello ![](cuepad://img/\(hash))")
    try await store.updateCard(card.id) {
      $0.numbering = .cjk
      $0.isFavorite = true
      $0.variableValues = ["k": "v"]
    }
    try await store.addTag("idea", to: card.id)
    let task = try await store.createTask("t", in: project.id)
    try await store.recordSend("x", to: SendTarget(kind: .piSession, name: "n", ref: "r"), card: card.id, task: task.id)
    try await store.registerAttachment(hash: hash, byteCount: 3, format: "png")
    return (card, hash)
  }

  @Test func everySyncedTableRoundTripsThroughCKRecord() async throws {
    _ = try await populate()
    let keys = try await store.pendingSync().saves
    #expect(Set(keys.map(\.table)) == Set(Table.synced))  // 七张同步表都有记录

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

    let names = ["projects": "name", "tasks": "content", "sendRecords": "content", "tags": "name"]
    for key in try await store.pendingSync().saves {
      guard let field = names[key.table.rawValue] else { continue }
      let other = RecordMapper.record(from: try #require(try await store.syncRow(recordName: key.id)), zoneID: testZone)
      #expect(other.encryptedValues[field] != nil && other[field] == nil)
    }
  }

  @Test func nilFieldsAreAbsentFromTheRecord() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let record = RecordMapper.record(from: try #require(try await store.syncRow(recordName: project.id.uuidString.lowercased())), zoneID: testZone)
    #expect(record["icon"] == nil && record["goalCardID"] == nil && record["deletedAt"] == nil)
  }

  @Test func unknownEnumValuesAreKeptVerbatimNotCoercedToKnownOnes() async throws {
    let send = remoteRecord(.sendRecords, sendFields(kind: "carrierPigeon", modifiedAt: 5_000))
    let card = remoteRecord(.cards, cardFields(project: nil, body: "b", modifiedAt: 5_000, numbering: "roman"))

    await rig.coordinator.handle(.fetched(modifications: [send, card], deletions: []))

    let records = try await store.sendRecords()
    #expect(records.map(\.targetKind) == [.unknown("carrierPigeon")])
    #expect(try await store.sendTargets().isEmpty)  // 没有关联卡片，不进目标列表
    let stored = try #require(try await store.cards(in: nil).first)
    #expect(stored.numbering == .unknown("roman"))

    // 原样推回：其他字段被编辑后，未知值不变
    try await store.updateCard(stored.id) { $0.isFavorite = true }
    let pushed = try #require(await rig.coordinator.record(for: card.recordID))
    #expect(pushed["numbering"] as? String == "roman")
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
