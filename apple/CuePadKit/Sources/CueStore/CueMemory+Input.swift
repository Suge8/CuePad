import Foundation

public enum CueMemoryInput: Equatable, Sendable {
  case line(CueMemoryLine)
  case summary(range: CueMemoryRange, text: String)
}

extension CueMemory {
  public static let rawMax = 16

  public func range(lo: Int, hi: Int) -> CueMemoryRange? {
    guard CueMemoryRange.aligned(lo, hi), hi <= lines.count else { return nil }
    let raw = CueMemoryRange.fingerprint(lines[lo..<hi])
    let fingerprint: String
    if hi - lo <= Self.rawMax {
      fingerprint = raw
    } else {
      let dependencies = summaryInput(lo: lo, hi: hi).flatMap { input -> [String] in
        switch input {
        case .line: []
        case .summary(let range, let text): [range.reference, text]
        }
      }
      fingerprint = CueMemoryRange.hash([raw] + dependencies)
    }
    return CueMemoryRange(lo: lo, hi: hi, fingerprint: fingerprint)
  }

  public func summaryInput(lo: Int, hi: Int) -> [CueMemoryInput] {
    if hi - lo <= Self.rawMax {
      return lines[lo..<hi].filter { $0.deletedAt == nil && !$0.pinned }.map { .line($0) }
    }
    let mid = (lo + hi) / 2
    return expanded(lo: lo, hi: mid) + expanded(lo: mid, hi: hi)
  }

  public func expanded(lo: Int, hi: Int) -> [CueMemoryInput] {
    if hi - lo == 1 {
      let line = lines[lo]
      return line.deletedAt == nil && !line.pinned ? [.line(line)] : []
    }
    if let summary = summaries.first(where: { $0.lo == lo && $0.hi == hi }) {
      return [.summary(range: range(lo: lo, hi: hi)!, text: summary.text)]
    }
    let mid = (lo + hi) / 2
    return expanded(lo: lo, hi: mid) + expanded(lo: mid, hi: hi)
  }
}
