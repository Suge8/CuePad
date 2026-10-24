import Foundation

// 说的话到哪了（`Speech`）要从库里读的事实：记录本身，加上它的同步元数据里服务器收下过没有。
// 都是读的时候推出来的，不另存：服务器收下一版就记在 syncRecords（`markPushed`），订阅读到这张表就会在那时被叫醒。

extension Speech {
  /// 表 `alias` 这一行服务器收下过（任一版）：SELECT 里推出 `reachedServer` 的那一列。别的设备写来的记录也收下过。
  static func reachedServerSQL(_ alias: String) -> String {
    "EXISTS (SELECT 1 FROM syncRecords s WHERE s.recordName = \(alias).id AND s.pushedModifiedAt IS NOT NULL)"
  }
}

extension DeliveryRequest {
  static var selection: String { (columns + [Speech.reachedServerSQL(table.rawValue)]).joined(separator: ", ") }
}

extension CueMessage {
  static var selection: String { (columns + [Speech.reachedServerSQL(table.rawValue)]).joined(separator: ", ") }
}

extension CueStore {
  /// 你最近一句对 Cue 说的话：写下的时刻、交给它的时刻与服务器收下过没有；你还没说过为 nil。到哪了由读的人按此刻推（`Speech.trip`，
  /// App 的"此刻"只在 `SpeechClock` 一处到点刷新），这里只给记录。不说 Cue 那台 Mac 在不在（那是 `macOnline`）。
  public func cueLastYou() throws -> (said: Date, delivered: Date?, reachedServer: Bool)? {
    try db.first(
      """
      SELECT createdAt, deliveredAt, \(Speech.reachedServerSQL("cueMessages")) FROM cueMessages WHERE author = 'you'
      ORDER BY createdAt DESC, rowid DESC LIMIT 1
      """
    ) { (said: $0.date(0), delivered: $0.dateOrNil(1), reachedServer: $0.bool(2)) }
  }
}
