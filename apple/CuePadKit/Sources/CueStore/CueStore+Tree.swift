import Foundation

extension CueStore {
  static func subtree(from seed: String, includingDeleted: Bool = false) -> String {
    """
    WITH RECURSIVE sub(id) AS (
      \(seed) UNION SELECT c.id FROM cards c JOIN sub ON c.parentID = sub.id WHERE \(includingDeleted ? "1" : "c.deletedAt IS NULL"))
    SELECT id FROM sub
    """
  }

  func link(of id: UUID) throws -> CardLinks.Link? {
    try db.first("SELECT parentID, projectID, todoAt IS NOT NULL FROM cards WHERE id = ? AND deletedAt IS NULL", [id]) {
      CardLinks.Link(parent: $0.uuidOrNil(0), project: $0.uuid(1), isTask: $0.bool(2))
    }
  }

  static func upChain(of seeds: String) -> String {
    """
    WITH RECURSIVE up(start, id, parentID) AS (
      SELECT c.id, c.id, c.parentID FROM cards c WHERE c.id IN (\(seeds))
      UNION SELECT up.start, p.id, p.parentID FROM cards p JOIN up ON p.id = up.parentID WHERE p.deletedAt IS NULL)
    """
  }

  func ancestors(of id: UUID) throws -> [UUID] {
    try db.query(
      Self.upChain(of: "SELECT id FROM cards WHERE id = ?1 AND deletedAt IS NULL") + " SELECT id FROM up WHERE id != ?1", [id]) { $0.uuid(0) }
  }

  static func tops(of seeds: String) -> String {
    upChain(of: seeds) + """
       SELECT start, id AS top FROM up
      WHERE parentID IS NULL OR NOT EXISTS (SELECT 1 FROM cards p WHERE p.id = up.parentID AND p.deletedAt IS NULL)
      """
  }

  func top(of id: UUID) throws -> UUID {
    try db.first(Self.tops(of: "SELECT ?"), [id]) { $0.uuid(1) } ?? id
  }

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
