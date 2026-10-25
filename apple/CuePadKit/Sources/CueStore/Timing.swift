import Foundation

/// 时间与休眠的来源。后台任务（状态合并、投送清理）只经它取时间与休眠，测试可换成手动推进的时钟。
public struct Timing: Sendable {
  public var now: @Sendable () -> Date
  public var sleep: @Sendable (Duration) async throws -> Void
  /// 睡到这一刻：等的是某个时刻（时限、到期）时用它。否决先算好时长再 `sleep`：任务晚一点才真正睡下，晚的那段又睡一遍，过点才醒。
  public var sleepUntil: @Sendable (Date) async throws -> Void

  /// `sleepUntil` 缺省按睡下那一刻的 `now` 算剩下的时长。
  public init(
    now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void,
    sleepUntil: (@Sendable (Date) async throws -> Void)? = nil
  ) {
    self.now = now
    self.sleep = sleep
    self.sleepUntil = sleepUntil ?? { try await sleep(.seconds(max(0, $0.timeIntervalSince(now())))) }
  }

  public static let system = Timing(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

extension Duration {
  /// 秒数（含小数），App 与 Kit 共用这一处换算。
  public var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
