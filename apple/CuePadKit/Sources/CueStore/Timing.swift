import Foundation

public struct Timing: Sendable {
  public var now: @Sendable () -> Date
  public var sleep: @Sendable (Duration) async throws -> Void
  public var sleepUntil: @Sendable (Date) async throws -> Void

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
  public var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
