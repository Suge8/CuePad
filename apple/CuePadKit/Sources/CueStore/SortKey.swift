import Foundation

/// 分数索引：字符串按字节序排序，任意两个键之间总能再插入一个键，
/// 因此移动一项只改它自己的键，多设备并发排序不会互相覆盖。
/// 键的最后一位永不为 "0"（否则其前面无法再插入）。
enum SortKey {
  private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
  private static let base = digits.count
  private static let middleDigit = base / 2

  /// 严格位于 lower 与 upper 之间的键；`nil` 表示对应一侧无界。lower >= upper（并发产生了相同键）时返回 nil。
  static func between(_ lower: String?, _ upper: String?) -> String? {
    if let lower, let upper, lower >= upper { return nil }
    let low = (lower ?? "").utf8.map(value)
    let high = upper.map { $0.utf8.map(value) }
    return String(midpoint(low[...], high?[...]).map { digits[$0] })
  }

  static func after(_ key: String?) -> String { between(key, nil)! }

  static func before(_ key: String?) -> String { between(nil, key)! }

  /// 初始化 count 个等宽、递增的键（导入、重排用）。
  static func sequence(count: Int) -> [String] {
    var width = 1
    var capacity = base
    while capacity < count {
      width += 1
      capacity *= base
    }
    return (0..<count).map { index in
      var number = index
      var digitsOfIndex: [Character] = []
      for _ in 0..<width {
        digitsOfIndex.append(digits[number % base])
        number /= base
      }
      return String(digitsOfIndex.reversed()) + String(digits[middleDigit])
    }
  }

  private static func value(_ byte: UInt8) -> Int { digits.firstIndex(of: Character(UnicodeScalar(byte)))! }

  private static func midpoint(_ low: ArraySlice<Int>, _ high: ArraySlice<Int>?) -> [Int] {
    if let high {
      var common = 0
      while common < high.count, digit(low, common) == high[high.startIndex + common] { common += 1 }
      if common > 0 {
        return Array(high.prefix(common))
          + midpoint(low.dropFirst(min(common, low.count)), high.dropFirst(common))
      }
    }
    let lowDigit = low.first ?? 0
    let highDigit = high?.first ?? base
    if highDigit - lowDigit > 1 { return [(lowDigit + highDigit) / 2] }
    if let high, high.count > 1 { return [high[high.startIndex]] }
    return [lowDigit] + midpoint(low.dropFirst(), nil)
  }

  private static func digit(_ slice: ArraySlice<Int>, _ offset: Int) -> Int {
    offset < slice.count ? slice[slice.startIndex + offset] : 0
  }
}
