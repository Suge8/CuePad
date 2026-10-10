import Foundation

extension CueStore {
  /// 全部会话记录数（在线的与历史）。
  public func piSessionCount() throws -> Int {
    try db.first("SELECT count(*) FROM piSessionStates") { Int($0.int(0)) } ?? 0
  }

  /// 一批 Pi 会话（Pi 的会话 id）的列表项，一次读出，按会话 id 索引；没有记录的 id 不在结果里。
  /// 列表项的内容与 `piSessionPage` 的一样（项目、最近一条投送请求、改名、没送达的话）；行与卡上要显示几十个会话的状态时用它，
  /// 不必一个会话查一次。
  public func piSessions(sessionIDs: [String]) throws -> [String: PiSessionListItem] {
    guard !sessionIDs.isEmpty else { return [:] }
    let states = try select(
      PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [Self.jsonList(sessionIDs)])
    let ids = states.map(\.sessionID)
    let projects = Dictionary(uniqueKeysWithValues: try self.projects().map { ($0.id, $0) })
    let deliveries = try latestDeliveries(to: ids)
    let renames = try latestRenames(to: ids)
    let undelivered = try undeliveredCounts(to: ids)
    return Dictionary(
      states.map {
        (
          $0.sessionID,
          PiSessionListItem(
            state: $0, project: $0.projectID.flatMap { projects[$0] }, delivery: deliveries[$0.sessionID], rename: renames[$0.sessionID],
            undelivered: undelivered[$0.sessionID] ?? 0)
        )
      }, uniquingKeysWith: { first, _ in first })
  }

  private static func jsonList(_ strings: [String]) -> String {
    String(decoding: try! JSONEncoder().encode(strings), as: UTF8.self)
  }
}
