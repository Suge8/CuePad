import Foundation

/// 层级查询（写入时的校验与连带操作用）：只问需要的那几行，走 `cards_parentID` 索引，不把全部卡片读成层级图。
/// 默认只看没删除的卡片；收尾查创建来源时子树可包含已删除节点。上级不在（没到、在回收站）的按顶层看待。递归用 `UNION`（去重）：远端并发留下的环到重复处就停。
extension CueStore {
  /// 子树（含起点）的 id 查询，作子查询用。`seed` 是给出起点 id 的查询，如 `SELECT ?3`。
  static func subtree(from seed: String, includingDeleted: Bool = false) -> String {
    """
    WITH RECURSIVE sub(id) AS (
      \(seed) UNION SELECT c.id FROM cards c JOIN sub ON c.parentID = sub.id WHERE \(includingDeleted ? "1" : "c.deletedAt IS NULL"))
    SELECT id FROM sub
    """
  }

  /// 卡片的上级、项目与是不是任务；没有或已在回收站为 nil。
  func link(of id: UUID) throws -> CardLinks.Link? {
    try db.first("SELECT parentID, projectID, todoAt IS NOT NULL FROM cards WHERE id = ? AND deletedAt IS NULL", [id]) {
      CardLinks.Link(parent: $0.uuidOrNil(0), project: $0.uuid(1), isTask: $0.bool(2))
    }
  }

  /// 往上走的规则只有这一条，表 `up(start, id, parentID)`（`WITH` 子句，后面接自己的 `SELECT`）：从每个起点（`seeds` 给出 id，起点删没删由它定）
  /// 沿在库里、没删的上级往上走，上级不在（没到、在回收站）就停在那里；行按自下而上的顺序出。
  static func upChain(of seeds: String) -> String {
    """
    WITH RECURSIVE up(start, id, parentID) AS (
      SELECT c.id, c.id, c.parentID FROM cards c WHERE c.id IN (\(seeds))
      UNION SELECT up.start, p.id, p.parentID FROM cards p JOIN up ON p.id = up.parentID WHERE p.deletedAt IS NULL)
    """
  }

  /// 在库里的上级，自下而上（`upChain`）；起点不在库里为空。任务在第几级是 `count + 1`（任务的上级都是任务）。
  func ancestors(of id: UUID) throws -> [UUID] {
    try db.query(
      Self.upChain(of: "SELECT id FROM cards WHERE id = ?1 AND deletedAt IS NULL") + " SELECT id FROM up WHERE id != ?1", [id]) { $0.uuid(0) }
  }

  /// 一件事的顶层，一行（起点, 顶层），作子查询用：`upChain` 走到头的那一个。
  /// 起点自己已删也照走：删掉的任务仍归原来那件事。远端并发留下的环里没有顶层，不出行。
  static func tops(of seeds: String) -> String {
    upChain(of: seeds) + """
       SELECT start, id AS top FROM up
      WHERE parentID IS NULL OR NOT EXISTS (SELECT 1 FROM cards p WHERE p.id = up.parentID AND p.deletedAt IS NULL)
      """
  }

  /// 所在那件事的顶层（`tops`）；不在库里的、在环里的是它自己。
  func top(of id: UUID) throws -> UUID {
    try db.first(Self.tops(of: "SELECT ?"), [id]) { $0.uuid(1) } ?? id
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
