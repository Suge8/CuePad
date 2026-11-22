enum SortKey {
  private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
  private static let base = digits.count
  private static let middleDigit = base / 2

  static func between(_ lower: String?, _ upper: String?) -> String? {
    if let lower, let upper, lower >= upper { return nil }
    let low = (lower ?? "").utf8.map(value)
    let high = upper.map { $0.utf8.map(value) }
    return String(midpoint(low[...], high?[...]).map { digits[$0] })
  }

  static func after(_ key: String?) -> String { between(key, nil)! }

  static func before(_ key: String?) -> String { between(nil, key)! }

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
