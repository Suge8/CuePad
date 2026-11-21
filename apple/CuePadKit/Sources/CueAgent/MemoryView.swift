import CueStore
import Foundation

public struct CueMemoryView: Equatable, Sendable {
  public typealias Entry = CueMemoryInput

  public struct Merge: Equatable, Sendable {
    public let range: CueMemoryRange
    public var source: String
  }

  public var pinned: [CueMemoryLine]
  public var entries: [Entry]
  public var merges: [Merge]
  public var pinnedBytes: Int
  public var pinnedOverBudget: Bool { pinnedBytes > CueMemoryLine.pinnedHard }
  private let memory: CueMemory
  private var lines: [CueMemoryLine] { memory.lines }

  public static let budget = 96
  private static let rawMax = CueMemory.rawMax

  public init(_ memory: CueMemory) {
    let budget = Self.budget
    let lines = memory.lines
    self.memory = memory
    pinned = lines.filter { $0.pinned && $0.deletedAt == nil }
    pinnedBytes = CueMemoryLine.bytes(pinned)
    var entries: [Entry] = [], merges: [Merge] = []
    func pending(_ lo: Int, _ hi: Int) {
      guard !memory.summaries.contains(where: { $0.lo == lo && $0.hi == hi }), memory.expanded(lo: lo, hi: hi).count > 1 else { return }
      if hi - lo > Self.rawMax {
        let mid = (lo + hi) / 2
        pending(lo, mid)
        pending(mid, hi)
        guard memory.expanded(lo: lo, hi: mid).count <= 1, memory.expanded(lo: mid, hi: hi).count <= 1 else { return }
      }
      let source = memory.summaryInput(lo: lo, hi: hi).map(\.text).joined(separator: "\n")
      merges.append(Merge(range: memory.range(lo: lo, hi: hi)!, source: source))
    }
    for (lo, hi) in Self.cover(lines.count, budget: max(0, budget - pinned.count)) {
      entries += memory.expanded(lo: lo, hi: hi)
      if hi - lo > 1 { pending(lo, hi) }
    }
    self.entries = entries
    self.merges = merges.sorted { ($0.range.hi - $0.range.lo, $0.range.lo) < ($1.range.hi - $1.range.lo, $1.range.lo) }
  }

  public var pinnedText: String {
    guard !pinned.isEmpty else { return "还没有。" }
    var out = ["\(pinned.count) 条，\(Self.kilobytes(pinnedBytes)) / \(Self.kilobytes(CueMemoryLine.pinnedHard))"]
    if pinnedOverBudget {
      out[0] += "：超了。按整理记忆的原则用 note replaces 合并重复项，过时的 forget，不必是重点的 pin false"
    }
    out += pinned.map { $0.shown() }
    return out.joined(separator: "\n")
  }

  static func kilobytes(_ bytes: Int) -> String {
    (Double(bytes) / 1024).formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX"))) + "KB"
  }

  public var viewText: String? {
    guard !entries.isEmpty else { return nil }
    return (["<memory>", "你的记忆（重点在系统提示里；其余从早到晚，越早越粗。一条是 UUID 记下的日期 [他] 正文，[他] 是他的原话；#a-b 是摘要的位置标签，展开时把 range 原样交给 memory zoom；读取当前视图用 memory zoom 不带 line 或 range）："] + entries.map(\.text) + ["</memory>"])
      .joined(separator: "\n")
  }

  public func zoom(range: CueMemoryRange) throws -> String {
    guard memory.range(lo: range.lo, hi: range.hi) == range else { throw CueStoreError.staleMemoryRange }
    let mid = range.lo + (range.hi - range.lo) / 2
    return [(range.lo, mid), (mid, range.hi)].map { start, end in
      if end - start == 1 { return raw(start) }
      let child = memory.range(lo: start, hi: end)!
      if let summary = memory.summaries.first(where: { $0.lo == start && $0.hi == end }) {
        return "\(child.label) range=\(child.reference) \(summary.text)"
      }
      if end - start > Self.rawMax { return "\(child.label) range=\(child.reference)（还没合并，再 zoom 展开）" }
      return (start..<end).map(raw).joined(separator: "\n")
    }.joined(separator: "\n")
  }

  private func raw(_ index: Int) -> String {
    let line = lines[index]
    return line.shown() + (line.deletedAt != nil ? "（已忘掉）" : line.pinned ? "（重点）" : "")
  }

  var mergeText: String? {
    guard !merges.isEmpty else { return nil }
    return merges.map { "\($0.range.label) range=\($0.range.reference)\n\($0.source)" }.joined(separator: "\n\n")
  }

  private static func cover(_ total: Int, alpha: Double) -> [(Int, Int)] {
    var root = 1
    while root < total { root *= 2 }
    var out: [(Int, Int)] = [], stack = [(0, root)]
    while let (lo, hi) = stack.popLast() {
      guard lo < total else { continue }
      let size = hi - lo
      if size > 1, hi > total || Double(size) > alpha * Double(total - lo) {
        let mid = (lo + hi) / 2
        stack.append((mid, hi))
        stack.append((lo, mid))
      } else {
        out.append((lo, hi))
      }
    }
    return out.sorted { $0.0 < $1.0 }
  }

  private static func cover(_ total: Int, budget: Int) -> [(Int, Int)] {
    guard total > 0 else { return [] }
    if total <= budget { return (0..<total).map { ($0, $0 + 1) } }
    var low = 0.0, high = 1.0
    for _ in 0..<60 {
      let mid = (low + high) / 2
      if cover(total, alpha: mid).count > budget { low = mid } else { high = mid }
    }
    var out = cover(total, alpha: high)
    while out.count < budget, let index = out.indices.last(where: { out[$0].1 - out[$0].0 > 1 }) {
      let (lo, hi) = out[index], mid = (lo + hi) / 2
      out.replaceSubrange(index...index, with: [(lo, mid), (mid, hi)])
    }
    return out
  }
}

extension CueMemoryInput {
  var text: String {
    switch self {
    case .line(let line): line.shown()
    case .summary(let range, let text): "\(range.label) range=\(range.reference) \(text)"
    }
  }
}

extension CueMemoryLine {
  func shown(now: Date = .now) -> String {
    "\(id.uuidString.lowercased()) \(Self.day(createdAt, now: now)) " + (source == .known(.you) ? "[他] " : "") + schedule(now: now) + text
  }

  private func schedule(now: Date) -> String {
    if let repeats { return "定时 \(CueScheduleWords.repeats(repeats))：" }
    guard let remindAt else { return "" }
    return "定时 \(Self.day(remindAt, now: now)) \(remindAt.formatted(CueEnvelope.clock))："
  }

  private static func day(_ date: Date, now: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    return date.formatted(sameYear ? CueEnvelope.monthDay : CueEnvelope.fullDay)
  }
}
