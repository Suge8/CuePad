import CueStore
import Foundation
import Testing

/// 其他版本的设备可能写入本版本不认识的枚举值：读出时保留原始值（`.unknown`），不当成已知值，写回时原样保留。
@Suite struct UnknownValueTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func unknownSendTargetKindIsPreservedNotTreatedAsAnApp() async throws {
    let card = try await store.createCard(in: nil, body: "x")
    let record = try await store.recordSend("s", to: SendTarget(kind: .app, name: "n"), card: card.id)
    try RawDB(fixture.url).exec("UPDATE sendRecords SET targetKind = 'carrierPigeon' WHERE id = '\(record.id.uuidString.lowercased())'")

    let read = try #require(try await store.sendRecords().first)
    #expect(read.targetKind == .unknown("carrierPigeon") && read.targetKind != .app)
    #expect(read.targetKind.rawValue == "carrierPigeon")
    #expect(try await store.lastSends(in: nil)[card.id]?.target.kind == .unknown("carrierPigeon"))
    #expect(try await store.sendTargets().map(\.kind) == [.unknown("carrierPigeon")])
    #expect(try await store.search(SearchQuery(sent: .sent(kind: .unknown("carrierPigeon")))).cards.map(\.id) == [card.id])
    #expect(try await store.search(SearchQuery(sent: .sent(kind: .app))).cards.isEmpty)
  }

  @Test func unknownNumberingIsPreservedAcrossOtherEdits() async throws {
    let card = try await store.createCard(in: nil, body: "x")
    try RawDB(fixture.url).exec("UPDATE cards SET numbering = 'roman' WHERE id = '\(card.id.uuidString.lowercased())'")

    #expect(try await store.card(card.id)?.numbering == .unknown("roman"))
    try await store.updateCard(card.id) { $0.isFavorite = true }  // 改别的字段
    #expect(try RawDB(fixture.url).rows("SELECT numbering FROM cards") == [["roman"]])
  }

  @Test func knownValuesRoundTripUnchanged() {
    for kind in [SendTargetKind.piSession, .app, .clipboard] { #expect(SendTargetKind(rawValue: kind.rawValue) == kind) }
    for numbering in [Numbering.none, .decimal, .alpha, .cjk] { #expect(Numbering(rawValue: numbering.rawValue) == numbering) }
  }
}
