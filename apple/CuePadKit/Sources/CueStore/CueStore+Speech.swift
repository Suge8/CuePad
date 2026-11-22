import Foundation

extension Speech {
  static func reachedServerSQL(_ alias: String) -> String {
    "EXISTS (SELECT 1 FROM syncRecords s WHERE s.recordName = \(alias).id AND s.pushedModifiedAt IS NOT NULL)"
  }
}

protocol AwaitsServer: Record {
  var unsentName: String? { get }
}

extension AwaitsServer {
  static func reachedServer(in row: Row) -> Bool { row.bool(row.index(of: "reachedServer")!) }

  static var selection: String { (columns + ["\(Speech.reachedServerSQL(table.rawValue)) AS reachedServer"]).joined(separator: ", ") }
}

extension DeliveryRequest: AwaitsServer {
  var unsentName: String? { !reachedServer && isWithdrawable ? id.uuidString.lowercased() : nil }
}

extension CueMessage: AwaitsServer {
  var unsentName: String? { !reachedServer && author == .known(.you) && deliveredAt == nil ? id.uuidString.lowercased() : nil }
}

extension CueStore {
  public func cueLastYou() throws -> (said: Date, delivered: Date?, reachedServer: Bool)? {
    let last = try db.untracked(.syncRecords) {
      try db.first(
        """
        SELECT id, createdAt, deliveredAt, \(Speech.reachedServerSQL("cueMessages")) FROM cueMessages WHERE author = 'you'
        ORDER BY createdAt DESC, rowid DESC LIMIT 1
        """
      ) { (id: $0.text(0), said: $0.date(1), delivered: $0.dateOrNil(2), reachedServer: $0.bool(3)) }
    }
    if let last, last.delivered == nil, !last.reachedServer { try dependOnUnsent([last.id]) }
    return last.map { ($0.said, $0.delivered, $0.reachedServer) }
  }

  func dependOnUnsent(_ names: [String]) throws {
    guard readScopes != nil, !names.isEmpty else { return }
    try narrow(
      .syncRecords, column: "recordName", candidates: "pushedModifiedAt IS NOT NULL AND recordName IN (SELECT value FROM json_each(?))",
      arguments: [JSONColumn.encode(names)], to: { _ in true }) { _ in }
  }
}
