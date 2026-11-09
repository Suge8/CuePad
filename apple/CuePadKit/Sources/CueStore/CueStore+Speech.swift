import Foundation

// 说的话到哪了（`Speech`）要从库里读的事实：记录本身，加上它的同步元数据里服务器收下过没有。
// 都是读的时候推出来的，不另存：服务器收下一版就记在 syncRecords（`markPushed`）。订阅只依赖读到的还没发出的那几句在这张表里的行
// （`dependOnUnsent`）：Mac 每小时推送几百次别的记录，不叫醒读说的话的订阅；那几句被收下时才叫醒。

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
  /// App 的"此刻"只在 `SpeechClock` 一处到点刷新），这里只给记录。不说 Cue 那台 Mac 在不在（那是 `macOnline`）。
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

  /// 订阅的这次读依赖这几句（还没发出的）在同步元数据里的行：它们被服务器收下（那一行有了 pushedModifiedAt）时叫醒，别的记录的推送、交出不叫醒。
  /// 不在订阅里读时没有要登记的，也就不查。
  func dependOnUnsent(_ names: [String]) throws {
    guard readScopes != nil, !names.isEmpty else { return }
    try narrow(
      .syncRecords, column: "recordName", candidates: "pushedModifiedAt IS NOT NULL AND recordName IN (SELECT value FROM json_each(?))",
      arguments: [JSONColumn.encode(names)], to: { _ in true }) { _ in }
  }
}
