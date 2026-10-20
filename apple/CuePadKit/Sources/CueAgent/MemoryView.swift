import CueStore
import Foundation

/// Cue 的记忆视图（OptMem 的读法）：一直记着的全部列出；其余按序号铺成对齐的 2 的幂块，越新越细、总行数固定在预算内
/// （按预算二分 alpha，见 `cover`）。块有摘要用摘要，没有就拆成两半直到有摘要或单行；缺的摘要列成"待合并"（`merges`），由值班的管理器空闲时逐块请 Cue 写，视图里不列（系统提示一个班次不变，列了也会过时）。
/// 参考 https://github.com/VictorTaelin/OptMem 的 `_cover` / `cover`。
public struct CueMemoryView: Equatable, Sendable {
  public enum Entry: Equatable, Sendable {
    case line(index: Int, text: String)
    case summary(lo: Int, hi: Int, text: String)
  }

  /// 待合并的一块：区间与原文（小块是原行，大块是两半的摘要）。
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

  /// 预算：视图最多这么多行（约 8k token）。
  public static let budget = 96
  /// 不超过这么多行的块直接从原行合并；更大的从两半的摘要合并。
  private static let rawMax = 16

  public init(_ memory: CueMemory) {
    let budget = Self.budget
    let lines = memory.lines
    let summaries = Dictionary(memory.summaries.map { ([$0.lo, $0.hi], $0.text) }, uniquingKeysWith: { _, last in last })
    pinned = lines.enumerated().filter { $1.pinned && $1.deletedAt == nil }.map { CueIndexedLine(index: $0, line: $1) }
    pinnedOverBudget = pinned.count > budget
    var entries: [Entry] = [], merges: [Merge] = []
    func expand(_ lo: Int, _ hi: Int) {
      if hi - lo == 1 {
        let line = lines[lo]
        if line.deletedAt == nil, !line.pinned { entries.append(.line(index: lo, text: line.text)) }
      } else if let text = summaries[[lo, hi]] {
        entries.append(.summary(lo: lo, hi: hi, text: text))
      } else {
        expand(lo, (lo + hi) / 2)
        expand((lo + hi) / 2, hi)
      }
    }
    func pending(_ lo: Int, _ hi: Int) {
      guard summaries[[lo, hi]] == nil else { return }
      let mid = (lo + hi) / 2
      if hi - lo <= Self.rawMax {
        let raw = (lo..<hi).filter { lines[$0].deletedAt == nil }.map { "#\($0) \(lines[$0].text)" }
        merges.append(Merge(lo: lo, hi: hi, source: raw.joined(separator: "\n")))
        return
      }
      let halves = [(lo, mid), (mid, hi)]
      let ready = halves.compactMap { half in summaries[[half.0, half.1]].map { "#\(half.0)-\(half.1 - 1) \($0)" } }
      if ready.count == 2 {
        merges.append(Merge(lo: lo, hi: hi, source: ready.joined(separator: "\n")))
      } else {
        for half in halves { pending(half.0, half.1) }
      }
    }
    for (lo, hi) in Self.cover(lines.count, budget: max(0, budget - pinned.count)) {
      expand(lo, hi)
      if hi - lo > 1 { pending(lo, hi) }
    }
    self.entries = entries
    self.merges = merges.sorted { ($0.hi - $0.lo, $0.lo) < ($1.hi - $1.lo, $1.lo) }
  }

  public var text: String {
    var out: [String] = []
    if !pinned.isEmpty {
      out.append("一直记着：")
      out += pinned.map { "#\($0.index) \($0.line.text)" }
      if pinnedOverBudget { out.append("（一直记着的太多，超出了记忆的预算：把能并的用 memory merge 合并，或 pin false 取消一些）") }
    }
    if !entries.isEmpty {
      out.append("其余（从早到晚，越早越粗）：")
      out += entries.map {
        switch $0 {
        case .line(let index, let text): "#\(index) \(text)"
        case .summary(let lo, let hi, let text): "#\(lo)-\(hi - 1) \(text)"
        }
      }
    }
    if out.isEmpty { out.append("还没有记忆。") }
    return out.joined(separator: "\n")
  }

  public static func mergePrompt(_ merge: Merge) -> String {
    """
    把记忆 #\(merge.lo)-\(merge.hi - 1) 合成一行（至多 \(CueMemoryLine.maxBytes) 字节），留下有长期影响的，不编造：
    \(merge.source)
    写回：memory merge {lo: \(merge.lo), hi: \(merge.hi), text}
    """
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
