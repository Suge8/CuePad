import CueStore
import CueText
import Foundation
import Testing

/// 其他版本的设备可能写入本版本不认识的枚举值：读出时保留原始值（`.unknown`），不当成已知值，写回时原样保留。
@Suite struct UnknownValueTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func unknownSendTargetKindIsPreservedNotTreatedAsKnown() async throws {
    let card = try await store.createCard(in: nil, body: "x")
    let record = try await store.recordSend("s", to: SendTarget(kind: .piSession, name: "n"), card: card.id)
    try RawDB(fixture.url).exec("UPDATE sendRecords SET targetKind = 'carrierPigeon' WHERE id = '\(record.id.uuidString.lowercased())'")

    let read = try #require(try await store.sendRecords().first)
    #expect(read.targetKind == .unknown("carrierPigeon") && read.targetKind != .known(.piSession))
    #expect(read.targetKind.rawValue == "carrierPigeon")
    #expect(try await store.lastSends(in: nil)[card.id]?.target.kind == .unknown("carrierPigeon"))
    #expect(try await store.sendTargets().map(\.kind) == [.unknown("carrierPigeon")])
    #expect(try await store.search(SearchQuery(sent: .sent(kind: .unknown("carrierPigeon")))).cards.map(\.id) == [card.id])
    #expect(try await store.search(SearchQuery(sent: .sent(kind: .known(.piSession)))).cards.isEmpty)
  }

  @Test func knownValuesRoundTripUnchanged() {
    for kind in SendTargetKind.allCases { #expect(Open<SendTargetKind>(rawValue: kind.rawValue) == .known(kind)) }
  }
}
