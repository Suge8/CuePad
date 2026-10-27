import CueStore
import Foundation

/// Cue 的记忆视图（OptMem 的读法）：一直记着的全部列出（在系统提示里，`pinnedText`）；其余按序号铺成对齐的 2 的幂块，越新越细、总行数固定在预算内
/// （按预算二分 alpha，见 `cover`），放在新会话的第一条输入里（`viewText`）。块有摘要用摘要，没有就拆成两半直到有摘要或单行；
/// 缺的摘要列成"待合并"（`merges`，由小到大、一批合到顶），视图里不列，由后台整理记忆的一次性大脑写（`mergeText`，`CueKeeper` 起）。摘要可以一层层展开（`zoom`）。
/// 参考 https://github.com/VictorTaelin/OptMem 的 `_cover` / `cover`。
public struct CueMemoryView: Equatable, Sendable {
  public enum Entry: Equatable, Sendable {
    case line(index: Int, line: CueMemoryLine)
    case summary(lo: Int, hi: Int, text: String)

    /// 视图里的写法：#序号 日期 [他] 正文（`CueMemoryLine.shown`），或 #a-b 摘要（b 含在内）
    var text: String {
      switch self {
      case .line(let index, let line): line.shown(at: index)
      case .summary(let lo, let hi, let text): "#\(lo)-\(hi - 1) \(text)"
      }
    }
  }

  /// 待合并的一块：区间与原文（小块是原行，不含忘掉的与一直记着的；大块是两半显示成的那一行，还要先合的指向同一批里排在前面的那一半）。
  public struct Merge: Equatable, Sendable {
    public var lo: Int
    public var hi: Int
    public var source: String
  }

  public var pinned: [CueIndexedLine]
  public var entries: [Entry]
  public var merges: [Merge]
  /// 一直记着的已超出预算：视图里提示合并或取消一些。
  public var pinnedOverBudget: Bool
  private let lines: [CueMemoryLine]
  private let summaries: [[Int]: String]

  /// 预算：视图最多这么多行（约 8k token）。
  public static let budget = 96
  /// 不超过这么多行的块直接从原行合并；更大的从两半的摘要合并。
  private static let rawMax = 16

  public init(_ memory: CueMemory) {
    let budget = Self.budget
    let lines = memory.lines
    let summaries = Dictionary(memory.summaries.map { ([$0.lo, $0.hi], $0.text) }, uniquingKeysWith: { _, last in last })
    (self.lines, self.summaries) = (lines, summaries)
    pinned = lines.enumerated().filter { $1.pinned && $1.deletedAt == nil }.map { CueIndexedLine(index: $0, line: $1) }
    pinnedOverBudget = pinned.count > budget
    var entries: [Entry] = [], merges: [Merge] = []
    // 区间在视图里显示成的几行：有摘要用摘要，没有就拆成两半，单行只列没忘掉、没一直记着的
    func expand(_ lo: Int, _ hi: Int) -> [Entry] {
      if hi - lo == 1 {
        let line = lines[lo]
        return line.deletedAt == nil && !line.pinned ? [.line(index: lo, line: line)] : []
      }
      if let text = summaries[[lo, hi]] { return [.summary(lo: lo, hi: hi, text: text)] }
      return expand(lo, (lo + hi) / 2) + expand((lo + hi) / 2, hi)
    }
    // 显示不止一行的块才待合并（全是一直记着的、忘掉的，或只剩一行，合了也不省行）；缺摘要的大块连同缺摘要的两半一起列出（小块排在前面）：
    // 一次换新就合到顶，不用等两半写好再等下一次换新
    func pending(_ lo: Int, _ hi: Int) {
      guard summaries[[lo, hi]] == nil, expand(lo, hi).count > 1 else { return }
      if hi - lo <= Self.rawMax {
        let raw = (lo..<hi).filter { lines[$0].deletedAt == nil && !lines[$0].pinned }.map { lines[$0].shown(at: $0) }
        merges.append(Merge(lo: lo, hi: hi, source: raw.joined(separator: "\n")))
        return
      }
      let halves = [(lo, (lo + hi) / 2), ((lo + hi) / 2, hi)]
      for half in halves { pending(half.0, half.1) }
      let source = halves.compactMap { half -> String? in
        let shown = expand(half.0, half.1)
        return shown.count > 1 ? "#\(half.0)-\(half.1 - 1)（上面先合的这一块写成的那一行）" : shown.first?.text
      }
      merges.append(Merge(lo: lo, hi: hi, source: source.joined(separator: "\n")))
    }
    for (lo, hi) in Self.cover(lines.count, budget: max(0, budget - pinned.count)) {
      entries += expand(lo, hi)
      if hi - lo > 1 { pending(lo, hi) }
    }
    self.entries = entries
    self.merges = merges.sorted { ($0.hi - $0.lo, $0.lo) < ($1.hi - $1.lo, $1.lo) }
  }

  /// 系统提示里的一直记着的（班次内不变）。
  public var pinnedText: String {
    guard !pinned.isEmpty else { return "还没有。" }
    var out = pinned.map { $0.line.shown(at: $0.index) }
    if pinnedOverBudget { out.append("（一直记着的太多，超出了记忆的预算：过时的 forget，不必一直记着的 pin false）") }
    return out.joined(separator: "\n")
  }

  /// 新会话第一条输入里的 `<memory>` 块：其余的记忆，从早到晚、越早越粗；没有为 nil。
  public var viewText: String? {
    guard !entries.isEmpty else { return nil }
    return (["<memory>", "你的记忆（一直记着的在系统提示里；其余从早到晚，越早越粗。一条是 #序号 记下的日期 [他] 正文，[他] 是他的原话；#a-b 是摘要，用 memory zoom 展开）："] + entries.map(\.text) + ["</memory>"])
      .joined(separator: "\n")
  }

  /// 展开 #lo-hi（hi 含在内，同视图里的写法）：两半各是摘要或原行，单行就是那一行。只展开对齐的块（视图与摘要里的 #a-b 都是）。
  public func zoom(lo: Int, hi: Int) -> String? {
    guard lo >= 0, hi >= lo, hi < lines.count else { return nil }
    if lo == hi { return raw(lo) }
    let size = hi + 1 - lo
    guard size & (size - 1) == 0, lo % size == 0 else { return nil }
    let mid = lo + size / 2
    return [(lo, mid), (mid, hi + 1)].map { half in
      let (start, end) = half
      if let text = summaries[[start, end]] { return "#\(start)-\(end - 1) \(text)" }
      if end - start > Self.rawMax { return "#\(start)-\(end - 1)（还没合并，再 zoom 展开）" }
      return (start..<end).map(raw).joined(separator: "\n")
    }.joined(separator: "\n")
  }

  private func raw(_ index: Int) -> String {
    let line = lines[index]
    return line.shown(at: index) + (line.deletedAt != nil ? "（已忘掉）" : line.pinned ? "（一直记着）" : "")
  }

  /// 交给整理记忆的大脑的待合并的块（规则在它的系统提示里，`CuePrompt.dream`）：由小到大，大块里还要先合的那一半指向排在前面的块；没有为 nil。
  public var mergeText: String? {
    guard !merges.isEmpty else { return nil }
    return merges.map { "#\($0.lo)-\($0.hi - 1)\n\($0.source)" }.joined(separator: "\n\n")
  }

  /// 用对齐的 2 的幂块铺满 [0, T)：块的大小不超过它年龄的 alpha 倍就整块保留。alpha 越大越粗、行越少。
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

  /// 至多 `budget` 块、越新越细：全放得下就一条一块；否则二分 alpha 取最细的、行数不超预算的铺法，余下的预算花在最新的块上。
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

extension CueMemoryLine {
  /// Cue 看到的一条记忆（记忆视图、一直记着、zoom、recall 与待合并的原文只有这一种写法）：#序号 日期 [他] 正文。
  /// 日期是记下的那天（本机时区，今年 10-21、往年 2025-10-21），[他] 只在他的原话（`source` 是 `you`）时有；摘要行不带。
  func shown(at index: Int, now: Date = .now) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let sameYear = calendar.component(.year, from: createdAt) == calendar.component(.year, from: now)
    let day = createdAt.formatted(sameYear ? CueEnvelope.monthDay : CueEnvelope.fullDay)
    return "#\(index) \(day) " + (source == .known(.you) ? "[他] " : "") + text
  }
}
