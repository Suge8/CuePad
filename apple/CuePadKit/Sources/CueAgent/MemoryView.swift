import CueStore
import Foundation

/// Cue 的记忆视图（OptMem 的读法）：重点全部列出（在系统提示里，`pinnedText`，过了 `CueMemoryLine.pinnedHard` 叫 Cue 自己收口）；其余按快照位置铺成对齐的 2 的幂块，越新越细、总行数固定在预算内
/// （按预算二分 alpha，见 `cover`），放在新会话的第一条输入里（`viewText`）。块有摘要用摘要，没有就拆成两半直到有摘要或单行；
/// 输入就绪的缺失摘要列成"待合并"（`merges`，子块写完由回执接续父块），视图里不列，由后台整理记忆的一次性大脑写（`dreamText`，`CueKeeper` 起；重点只归 Cue 整理，做梦不碰）。摘要可以一层层展开（`zoom`）。
/// 参考 https://github.com/VictorTaelin/OptMem 的 `_cover` / `cover`。
public struct CueMemoryView: Equatable, Sendable {
  public typealias Entry = CueMemoryInput

  /// 待合并的一块：区间与原文（小块是原行，不含忘掉的与重点；大块是已经就绪的两半输入）。
  public struct Merge: Equatable, Sendable {
    public let range: CueMemoryRange
    public var source: String
  }

  public var pinned: [CueMemoryLine]
  public var entries: [Entry]
  public var merges: [Merge]
  /// 重点合计字节（`CueMemoryLine.bytes`）
  public var pinnedBytes: Int
  /// 重点过了硬线（`CueMemoryLine.pinnedHard`）：系统提示里叫 Cue 合并
  public var pinnedOverBudget: Bool { pinnedBytes > CueMemoryLine.pinnedHard }
  private let memory: CueMemory
  private var lines: [CueMemoryLine] { memory.lines }

  /// 预算：视图最多这么多行（约 8k token）。
  public static let budget = 96
  /// 不超过这么多行的块直接从原行合并；更大的从两半的摘要合并。
  private static let rawMax = CueMemory.rawMax

  public init(_ memory: CueMemory) {
    let budget = Self.budget
    let lines = memory.lines
    self.memory = memory
    pinned = lines.filter { $0.pinned && $0.deletedAt == nil }
    pinnedBytes = CueMemoryLine.bytes(pinned)
    var entries: [Entry] = [], merges: [Merge] = []
    // 只发布输入已经就绪的块；子块完成后，工具回执发布新就绪的父块。
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

  /// 系统提示里的重点（班次内不变）：先一行用量，过了硬线跟一句叫 Cue 合并。
  public var pinnedText: String {
    guard !pinned.isEmpty else { return "还没有。" }
    var out = ["\(pinned.count) 条，\(Self.kilobytes(pinnedBytes)) / \(Self.kilobytes(CueMemoryLine.pinnedHard))"]
    if pinnedOverBudget {
      out[0] += "：超了。按整理记忆的原则用 note replaces 合并重复项，过时的 forget，不必是重点的 pin false"
    }
    out += pinned.map { $0.shown() }
    return out.joined(separator: "\n")
  }

  /// "3.2KB"：一位小数，整数不带 .0。
  static func kilobytes(_ bytes: Int) -> String {
    (Double(bytes) / 1024).formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX"))) + "KB"
  }

  /// 交给整理记忆的大脑的输入（规则在它的系统提示里，`CuePrompt.dream`）：待合并的块（`mergeText`）；没有为 nil。
  public var dreamText: String? { mergeText.map { "<merge>\n\($0)\n</merge>" } }

  /// 新会话第一条输入里的 `<memory>` 块：其余的记忆，从早到晚、越早越粗；没有为 nil。
  public var viewText: String? {
    guard !entries.isEmpty else { return nil }
    return (["<memory>", "你的记忆（重点在系统提示里；其余从早到晚，越早越粗。一条是 UUID 记下的日期 [他] 正文，[他] 是他的原话；#a-b 是摘要的位置标签，展开时把 range 原样交给 memory zoom；读取当前视图用 memory zoom 不带 line 或 range）："] + entries.map(\.text) + ["</memory>"])
      .joined(separator: "\n")
  }

  /// 展开快照中的区间；迟到插入或区间内事实变化时拒绝，避免旧范围指向另一批内容。
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

  /// 输入已经就绪的待合并块；没有为 nil。
  var mergeText: String? {
    guard !merges.isEmpty else { return nil }
    return merges.map { "\($0.range.label) range=\($0.range.reference)\n\($0.source)" }.joined(separator: "\n\n")
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

extension CueMemoryInput {
  /// 范围引用也属于模型读取的子块输入，随依赖一起更新。
  var text: String {
    switch self {
    case .line(let line): line.shown()
    case .summary(let range, let text): "\(range.label) range=\(range.reference) \(text)"
    }
  }
}

extension CueMemoryLine {
  /// Cue 看到的一条记忆（记忆视图、重点、zoom、recall 与待合并的原文只有这一种写法）：UUID 日期 [他] 定时 正文。
  /// 日期是记下的那天（本机时区，今年 10-21、往年 2025-10-21），[他] 只在他的原话（`source` 是 `you`）时有；摘要行不带。
  /// 定时写到点的时刻（一次的）或怎么重复：正文是写给到点那时的（"今天 15:00 的飞机"），只挂在记下的日期下面会被读成记下那天
  /// （长程评测里问行程，答成记下那天的 15:00）。
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
