import CueStore
import Foundation
import os

/// 有理由等就拉：Mac 不收推送，别的设备写来的东西只靠拉；手机的推送不保证送达与时效。手里有正在等的东西时，
/// 按条件给出的节奏拉（等什么只在 `AppServices.pollingCadence` 定义）。
///
/// 节奏变了（多了或换了在等的东西）先立即拉一次，最新状态不等第一个间隔。条件流的第一个值与重给的同一个节奏不立即拉：开始拉取（启动、回到前台）与同步恢复时 App 本来就立即同步，那一拉就是这一拉。
/// 节奏与拉取都不在调用方的线程上跑（`run` 是 `@concurrent`）：App 从主线程开它，主线程忙时拉取不跟着晚，`fetch` 也别回到主线程。
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

  /// 间隔从上一次开拉算起（拉的耗时算在间隔里）：服务器上新到的东西最多等一个间隔加一次拉取就到。
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
  /// 别的设备写来的东西平均约 1 秒、最坏约 2 秒到。
  /// Mac 不收推送，门铃不通时这一拉是别的设备的改动到 Mac 的唯一通路，不放慢。
  /// `doorbell`：门铃通着时降到的兜底间隔（只补门铃自己察觉不到的丢失，由门铃给出，`Relay.silenceLimit`）；nil 是门铃不通。
  public static func mac(waiting: Bool, doorbell: Duration?) -> Self? {
    waiting ? Self(every: doorbell ?? .seconds(2)) : nil
  }

  /// 有发往 Mac 还没结果的请求时每次在等最多 2 分钟：等回执的时限 `Speech.receiptLimit` 是 1 分钟，报了没能送达之后还接着拉一分钟，晚到的回执照样拉回来；再晚的靠推送。
  /// 正在看的页（Agent、会话近况、Cue）状态与对话是活的，不只靠推送。
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
