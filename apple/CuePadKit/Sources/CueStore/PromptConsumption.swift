import Foundation

/// 提示词是准备发给任务那个 Agent 会话的话：确认送达就用掉，从资料库里彻底删掉（不进归档、不进回收站），原话在会话里，
/// 发送记录照旧留着快照（`purgeCards` 把它的 `cardID` 置空）。资料（`isPinned`）与任务、没挂在任务下的灵感永远不删。
/// 没送到的留在原地可重发。规则只有一处：投送请求写下成功结果的同一个事务里（`finishDelivery`），以及升级时清掉旧库里已发出的（`Schema.upgrades`）。
/// 同步表的删除不需要另记：行不在了，下次对账（`pendingDeletes`）就是服务器上要删的记录。
extension CueStore {
  /// 表 `alias` 里的这张卡是提示词：挂在任务下的灵感，不是资料。
  static func isPrompt(_ alias: String) -> String { "\(alias).todoAt IS NULL AND \(alias).parentID IS NOT NULL AND \(alias).isPinned = 0" }

  /// 表 `alias`（投送请求）里的请求是发给会话的方式或开新会话：这些请求成功就算提示词送达。
  static func delivers(_ alias: String) -> String { "(\(alias).mode = 'start' OR \(alias).mode IN (\(toSessionModes)))" }

  /// 开新会话的请求（`deliveryRequests` 里的一行）还没等到那个会话的记录：认领（`claimLaunchedCards`）要等它。
  static let launchUnclaimed = """
    NOT EXISTS (SELECT 1 FROM piSessionStates s
      WHERE s.launchToken = CASE WHEN json_valid(deliveryRequests.content) THEN json_extract(deliveryRequests.content, '$.token') END)
    """

  /// 请求 `request` 刚写下成功结果：它带着的提示词用掉。返回因此不再被引用的图片（交给 `reclaimAttachments`）。
  func consumePrompt(deliveredBy request: UUID) throws -> Set<String> {
    let prompts = try db.query(
      """
      SELECT c.id FROM deliveryRequests r JOIN cards c ON c.id = r.cardID
      WHERE r.id = ? AND \(Self.delivers("r")) AND \(Self.isPrompt("c"))
      """, [request]
    ) { $0.uuid(0) }
    return try Self.consumePrompts(prompts, in: db)
  }

  /// 删掉这些（已送达的）提示词，任务记下的会话保留：
  /// - 开新会话的请求还在等会话记录时改记到任务上，会话开好后认领的是任务（`claimLaunchedCards`）；其余带着它的请求不再指向它；
  /// - 提示词上记着会话而任务还没有的（认领到了提示词上的新会话），转到任务上；任务没做完就算进行中。
  static func consumePrompts(_ prompts: [UUID], in db: SQLite) throws -> Set<String> {
    var images: Set<String> = []
    for prompt in prompts {
      let now = Date.stamp
      try db.run(
        """
        UPDATE deliveryRequests SET modifiedAt = ?2,
          cardID = CASE WHEN mode = 'start' AND status = 'succeeded' AND \(launchUnclaimed) THEN (SELECT parentID FROM cards WHERE id = ?1) END
        WHERE cardID = ?1
        """, [prompt, now])
      try db.run(
        """
        UPDATE cards SET piSessionID = (SELECT piSessionID FROM cards WHERE id = ?1), modifiedAt = ?2,
          startedAt = CASE WHEN completedAt IS NULL THEN COALESCE(startedAt, ?2) ELSE startedAt END
        WHERE id = (SELECT parentID FROM cards WHERE id = ?1) AND piSessionID IS NULL
          AND (SELECT piSessionID FROM cards WHERE id = ?1) IS NOT NULL
        """, [prompt, now])
      images.formUnion(try purgeCards(where: "id = ?", [prompt], in: db))
    }
    return images
  }
}
