import Foundation

extension CueStore {
  /// 顺序补读；读游标只在消费者完成这一行后前移。空页的 through 跨过已删除的行。
  public func cueMessagePage(after cursor: Int, limit: Int = 64) throws -> CueMessagePage {
    let end = try lastWrite()
    let rows = try db.query(
      "SELECT \(CueMessage.selection), writeSeq FROM cueMessages WHERE writeSeq > ? AND writeSeq <= ? ORDER BY writeSeq LIMIT ?", [cursor, end, limit]
    ) { CueMessagePage.Entry(message: CueMessage(row: $0), sequence: Int($0.int($0.index(of: "writeSeq")!))) }
    return CueMessagePage(entries: rows, through: rows.last?.sequence ?? end)
  }
}

public struct CueMessagePage: Sendable {
  public struct Entry: Sendable {
    public let message: CueMessage
    public let sequence: Int
  }
  public let entries: [Entry]
  public let through: Int
}
