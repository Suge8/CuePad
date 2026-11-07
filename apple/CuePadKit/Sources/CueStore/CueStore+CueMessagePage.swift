import Foundation

extension CueStore {
  /// 工具结果给出了准确消息身份后，关联调用开始时 Cue 已接走的请求；空数组确认是主动消息。
  /// 先写出的正文仍可查看，来源未确认前不自动交给语音；不得用最新一轮或时间邻近代认。
  public func associateCueReply(_ id: UUID, answering requests: [UUID]) throws {
    try write {
      try db.run("UPDATE cueMessages SET answeredRequests = ?, modifiedAt = ? WHERE id = ? AND author = 'cue' AND answeredRequests IS NULL",
                 [JSONColumn.encode(requests), Date.stamp, id])
    }
  }

  /// 已知请求的当前记录：送达与同步回执会变，按 ID 订阅，不受最近消息窗口限制。
  public func cueMessages(_ ids: [UUID]) throws -> [CueMessage] {
    try select(CueMessage.self, where: "id IN (SELECT lower(value) FROM json_each(?))", [JSONColumn.encode(ids)])
  }

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
