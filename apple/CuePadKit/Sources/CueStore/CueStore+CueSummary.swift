import Foundation

extension CueStore {
  /// 摘要是派生缓存：生成时的区间输入仍相同才提交，比较与写入在同一事务内。
  /// 不检查当前视图是否仍需要这块：区间外追加可能改变布局，却不会改变这块摘要的事实。
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
