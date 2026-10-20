import Foundation

/// 层级查询（写入时的校验与连带操作用）：只问需要的那几行，走 `cards_parentID` 索引，不把全部卡片读成层级图。
/// 只看没删除的卡片；上级不在（没到、在回收站）的按顶层看待。递归用 `UNION`（去重）：远端并发留下的环到重复处就停。
extension CueStore {
  /// 子树（含起点）的 id 查询，作子查询用。`seed` 是给出起点 id 的查询，如 `SELECT ?3`。
  static func subtree(from seed: String) -> String {
    """
    WITH RECURSIVE sub(id) AS (
      \(seed) UNION SELECT c.id FROM cards c JOIN sub ON c.parentID = sub.id WHERE c.deletedAt IS NULL)
    SELECT id FROM sub
    """
  }

  /// 卡片的上级、项目与是不是任务；没有或已在回收站为 nil。
  func link(of id: UUID) throws -> CardLinks.Link? {
    try db.first("SELECT parentID, projectID, todoAt IS NOT NULL FROM cards WHERE id = ? AND deletedAt IS NULL", [id]) {
      CardLinks.Link(parent: $0.uuidOrNil(0), project: $0.uuid(1), isTask: $0.bool(2))
    }
  }

  /// 在库里的上级，自下而上；任务在第几级是 `count + 1`（任务的上级都是任务）。
  func ancestors(of id: UUID) throws -> [UUID] {
    try db.query(
      """
      WITH RECURSIVE up(id, parentID) AS (
        SELECT id, parentID FROM cards WHERE id = ?1 AND deletedAt IS NULL
        UNION SELECT c.id, c.parentID FROM cards c JOIN up ON c.id = up.parentID WHERE c.deletedAt IS NULL)
      SELECT id FROM up WHERE id != ?1
      """, [id]) { $0.uuid(0) }
  }

  /// 任务连自己在内往下有几级任务（挂在下面的灵感不算一级）。只数到 `Card.maxTaskDepth`：判断超限够了，也让环里的数据数得完。
  func taskHeight(of id: UUID) throws -> Int {
    try db.first(
      """
      WITH RECURSIVE sub(id, depth) AS (
        SELECT ?1, 1 UNION SELECT c.id, sub.depth + 1 FROM cards c JOIN sub ON c.parentID = sub.id
        WHERE c.deletedAt IS NULL AND c.todoAt IS NOT NULL AND sub.depth < ?2)
      SELECT MAX(depth) FROM sub
      """, [id, Card.maxTaskDepth]) { Int($0.int(0)) } ?? 1
  }
}
