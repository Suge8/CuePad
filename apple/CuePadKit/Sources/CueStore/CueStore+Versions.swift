import Foundation

extension CueStore {
  static let guards = """
    CREATE TEMP TABLE remoteCopy (active INTEGER NOT NULL);
    INSERT INTO remoteCopy VALUES (0);
    """ + Table.synced.map { table in
      """
      CREATE TEMP TRIGGER \(table.rawValue)_newerVersion AFTER UPDATE OF modifiedAt ON \(table.rawValue)
      WHEN new.modifiedAt <= old.modifiedAt AND (SELECT active FROM remoteCopy) = 0
      BEGIN UPDATE \(table.rawValue) SET modifiedAt = old.modifiedAt + 1 WHERE id = new.id; END;
      """
    }.joined(separator: "\n")

  func copyingRemote(_ body: () throws -> Void) throws {
    try db.exec("UPDATE remoteCopy SET active = 1")
    try body()
    try db.exec("UPDATE remoteCopy SET active = 0")
  }
}
