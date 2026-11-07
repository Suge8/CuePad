import CryptoKit
import Foundation

/// 一份记忆快照中对齐的 [lo, hi) 区间。位置只用于布局，指纹绑定有序输入；范围引用跨进程原样传递，
/// 不能用写入时的输入重新盖章。指纹同时用于缓存有效性、zoom 与摘要事务比较，避免三处定义漂移。
public struct CueMemoryRange: Equatable, Sendable {
  public let lo: Int
  public let hi: Int
  public let fingerprint: String

  public var reference: String { "\(lo):\(hi):\(fingerprint)" }
  public var label: String { "#\(lo)-\(hi - 1)" }

  public init?(reference: String) {
    let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let lo = Int(parts[0]), let hi = Int(parts[1]), Self.aligned(lo, hi),
          parts[2].count == 64, parts[2].allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
    self.lo = lo
    self.hi = hi
    fingerprint = String(parts[2])
  }

  init(lo: Int, hi: Int, fingerprint: String) {
    self.lo = lo
    self.hi = hi
    self.fingerprint = fingerprint
  }

  static func aligned(_ lo: Int, _ hi: Int) -> Bool {
    guard lo >= 0, hi > lo else { return false }
    let size = hi - lo
    return size >= 2 && size & (size - 1) == 0 && lo % size == 0
  }

  /// 长度前缀保留字段和行的边界；内容参与比较，不依赖可能同毫秒的 modifiedAt。
  static func fingerprint(_ lines: ArraySlice<CueMemoryLine>) -> String {
    let fields = lines.flatMap { line in
      [line.id.uuidString, line.text, line.source.rawValue, String(line.createdAt.timeIntervalSince1970),
       line.deletedAt == nil ? "kept" : "deleted", line.pinned ? "pinned" : "plain",
       line.remindAt.map { String($0.timeIntervalSince1970) } ?? "", line.repeats?.rule ?? "", line.task?.uuidString ?? ""]
    }
    return hash(fields)
  }

  static func hash(_ fields: [String]) -> String {
    let input = fields.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
