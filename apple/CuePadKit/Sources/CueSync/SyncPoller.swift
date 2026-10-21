import CueStore
import Foundation

/// 有理由等就拉：Mac 不收推送，别的设备写来的东西只靠拉；手机的推送不保证送达与时效。手里有正在等的东西时，
/// 按条件给出的节奏拉（等什么只在 `AppServices.pollingCadence` 定义）。
///
/// 条件流给出此刻的节奏（nil：不在等）：每收到一个节奏就从头开始按它的档位隔着拉；节奏变了（多了或换了在等的东西）先立即拉一次，
/// 最新状态不等第一个间隔。条件流的第一个值与重给的同一个节奏不立即拉：开始拉取（启动、回到前台）与同步恢复时 App 本来就立即同步，
/// 那一拉就是这一拉。收到 nil 即停，条件流结束或任务取消时返回。
public struct SyncPoller: Sendable {
  /// 怎么拉：每 `interval` 拉一次，持续 `lasting`（nil 是一直），到期就不再拉。
  public struct Cadence: Equatable, Sendable {
    public var interval: Duration
    public var lasting: Duration?

    public init(every interval: Duration, for lasting: Duration? = nil) {
      self.interval = interval
      self.lasting = lasting
    }

    /// 在等了 `elapsed` 之后该隔多久拉一次；nil：到期了，不再拉。
    func interval(after elapsed: Duration) -> Duration? {
      if let lasting, elapsed >= lasting { return nil }
      return interval
    }
  }

  public var timing: Timing

  public init(timing: Timing = .system) {
    self.timing = timing
  }

  public func run<Condition: AsyncSequence & Sendable>(
    while waiting: Condition, fetch: @escaping @Sendable () async -> Void
  ) async where Condition.Element == Cadence?, Condition.Failure == Never {
    var cadences = waiting.makeAsyncIterator()
    guard var current = await cadences.next(isolation: #isolation) else { return }
    var loop = start(current, now: false, fetch)
    while let next = await cadences.next(isolation: #isolation) {
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

  /// 按走到哪一档隔着拉（`now`：先拉一次），直到档位走完或被取消（新节奏到来、不再等）。间隔从上一次开拉算起（拉的耗时算在间隔里）：
  /// 服务器上新到的东西最多等一个间隔加一次拉取就到。
  private func loop(_ cadence: Cadence, now: Bool, _ fetch: @escaping @Sendable () async -> Void) async {
    let start = timing.now()
    var began = now ? nil : start
    while !Task.isCancelled, let interval = cadence.interval(after: .seconds(timing.now().timeIntervalSince(start))) {
      if let began {
        let spent = Duration.seconds(timing.now().timeIntervalSince(began))
        if spent < interval { try? await timing.sleep(interval - spent) }
        guard !Task.isCancelled, cadence.interval(after: .seconds(timing.now().timeIntervalSince(start))) != nil else { return }
      }
      began = timing.now()
      await Task { await fetch() }.value  // 新节奏到来只打断睡眠，不打断拉了一半的请求（取消会让它报错）。取消屏蔽 withTaskCancellationShield 要 macOS 27，部署目标是 26
    }
  }
}

extension SyncPoller.Cadence {
  /// Mac：在等（等什么见 `AppServices.pollingCadence`）时每 2 秒，别的设备写来的东西平均约 1 秒、最坏约 2 秒到。
  /// Mac 上会话一连几天，这是一天四万多次；Mac 不收推送，所以不放慢（docs/sync.md「拉取节奏」）。
  public static func mac(waiting: Bool) -> Self? {
    waiting ? Self(every: .seconds(2)) : nil
  }

  /// 手机：有发往 Mac 还没结果的请求时每 2 秒、每次在等最多 2 分钟（等回执的时限 `Speech.receiptLimit` 是 1 分钟：
  /// 报了没能送达之后还接着拉一分钟，晚到的回执照样拉回来；再晚的靠推送）；正在看 Agent 页、会话近况或 Cue 页时每 3 秒
  /// （状态与对话是活的，不只靠推送），离开即停；两者都有时每 2 秒、不限时。
  public static func phone(hasOpenDeliveries: Bool, isWatching: Bool) -> Self? {
    switch (hasOpenDeliveries, isWatching) {
    case (true, true): Self(every: .seconds(2))
    case (true, false): Self(every: .seconds(2), for: .seconds(120))
    case (false, true): Self(every: .seconds(3))
    case (false, false): nil
    }
  }
}
