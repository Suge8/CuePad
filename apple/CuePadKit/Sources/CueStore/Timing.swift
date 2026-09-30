import Foundation

/// 时间与休眠的来源。后台任务（状态合并、投送清理、探针超时）只经它取时间与休眠，测试可换成手动推进的时钟。
public struct Timing: Sendable {
  public var now: @Sendable () -> Date
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.now = now
    self.sleep = sleep
  }

  public static let system = Timing(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

extension Duration {
  var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
