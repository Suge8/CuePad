import Foundation

extension CueStore {
  public func setCueSummary(range: CueMemoryRange, text: String) throws {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CueStoreError.blankTaskContent }
    guard CueMemoryLine.fits(text) else { throw CueStoreError.memoryLineTooLong(CueMemoryLine.maxBytes) }
    try write {
      let memory = try cueMemory()
      guard memory.range(lo: range.lo, hi: range.hi) == range else { throw CueStoreError.staleMemoryRange }
      try db.run(
        """
        INSERT INTO cueSummaries (lo, hi, text, lineIDs, createdAt) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(lo, hi) DO UPDATE SET text = excluded.text, lineIDs = excluded.lineIDs, createdAt = excluded.createdAt
        """, [range.lo, range.hi, text, range.fingerprint, Date.stamp])
    }
  }
}
