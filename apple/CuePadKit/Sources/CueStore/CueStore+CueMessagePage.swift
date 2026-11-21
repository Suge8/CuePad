import Foundation

extension CueStore {
  public func associateCueReply(_ id: UUID, answering requests: [UUID]) throws {
    try write {
      try db.run("UPDATE cueMessages SET answeredRequests = ?, modifiedAt = ? WHERE id = ? AND author = 'cue' AND answeredRequests IS NULL",
                 [JSONColumn.encode(requests), Date.stamp, id])
    }
  }

  public func cueMessages(_ ids: [UUID]) throws -> [CueMessage] {
    try select(CueMessage.self, where: "id IN (SELECT lower(value) FROM json_each(?))", [JSONColumn.encode(ids)])
  }

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
