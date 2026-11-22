import Foundation

extension CueStore {
  public func keepHabit(_ rule: String, telling text: String) throws {
    try write {
      if let id = try db.first("SELECT id FROM cueLines WHERE text = ? AND deletedAt IS NULL ORDER BY createdAt, id LIMIT 1", [rule], { $0.uuid(0) }) {
        try db.run("UPDATE cueLines SET pinned = 1, modifiedAt = ? WHERE id = ? AND pinned = 0", [Date.stamp, id])
      } else {
        _ = try insertLine(rule, source: .you, pinned: true)
      }
      _ = try putCueMessage(.cue, text: text)
    }
  }
}
