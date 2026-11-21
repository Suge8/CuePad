import CueStore
import Foundation
import os

public struct SyncPoller: Sendable {
  public struct Cadence: Equatable, Sendable {
    public var interval: Duration
    public var lasting: Duration?

    public init(every interval: Duration, for lasting: Duration? = nil) {
      self.interval = interval
      self.lasting = lasting
    }

    func interval(after elapsed: Duration) -> Duration? {
      if let lasting, elapsed >= lasting { return nil }
      return interval
    }
  }

  public var timing: Timing

  public init(timing: Timing = .system) {
    self.timing = timing
  }

  @concurrent
  public func run<Condition: AsyncSequence & Sendable>(
    while waiting: Condition, fetch: @escaping @Sendable () async -> Void
  ) async where Condition.Element == Cadence?, Condition.Failure == Never {
    var cadences = waiting.makeAsyncIterator()
    guard var current = await cadences.next(isolation: nil) else { return }
    var loop = start(current, now: false, fetch)
    while let next = await cadences.next(isolation: nil) {
      loop?.cancel()
      loop = start(next, now: next != current, fetch)
      current = next
    }
    loop?.cancel()
    await loop?.value
  }

  private func start(_ cadence: Cadence?, now: Bool, _ fetch: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
    cadence.map { cadence in Task { await self.loop(cadence, now: now, fetch) } }
  }

  private func loop(_ cadence: Cadence, now: Bool, _ fetch: @escaping @Sendable () async -> Void) async {
    let start = timing.now()
    var began = now ? nil : start
    while !Task.isCancelled, let interval = cadence.interval(after: .seconds(timing.now().timeIntervalSince(start))) {
      if let began {
        let spent = Duration.seconds(timing.now().timeIntervalSince(began))
        if spent < interval {
          let due = timing.now().addingTimeInterval((interval - spent).seconds)
          try? await timing.sleepUntil(due)
          let late = timing.now().timeIntervalSince(due)
          if late > Self.stallThreshold { Logger.stall.notice("拉取节奏的睡眠迟醒 \(late, format: .fixed(precision: 2), privacy: .public) 秒") }
        }
        guard !Task.isCancelled, cadence.interval(after: .seconds(timing.now().timeIntervalSince(start))) != nil else { return }
      }
      let fetching = timing.now()
      began = fetching
      await Task { await fetch() }.value  // 新节奏到来只打断睡眠，不打断拉了一半的请求（取消会让它报错）。取消屏蔽 withTaskCancellationShield 要 macOS 27，部署目标是 26
      let took = timing.now().timeIntervalSince(fetching)
      if took > Self.stallThreshold { Logger.stall.notice("一拉用了 \(took, format: .fixed(precision: 2), privacy: .public) 秒") }
    }
  }

  private static let stallThreshold: TimeInterval = 1
}

extension SyncPoller.Cadence {
  public static func mac(waiting: Bool, doorbell: Duration?) -> Self? {
    waiting ? Self(every: doorbell ?? .seconds(2)) : nil
  }

  public static func phone(hasOpenDeliveries: Bool, isWatching: Bool, doorbell: Duration?) -> Self? {
    let cadence: Self? =
      switch (hasOpenDeliveries, isWatching) {
      case (true, true): Self(every: .seconds(2))
      case (true, false): Self(every: .seconds(2), for: .seconds(120))
      case (false, true): Self(every: .seconds(3))
      case (false, false): nil
      }
    guard let doorbell, var cadence else { return cadence }
    cadence.interval = doorbell
    return cadence
  }
}
