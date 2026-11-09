import Foundation

extension DeliveryExecutor {
  /// 发出的话与 Cue 的失败请求最多留多久（与对话的保留期一样是 7 天）。
  static let keptRetention: TimeInterval = 7 * 86_400

  /// 在 `wake`（缺省是保留期后）清理一轮；已排了不晚于它的就不动，更晚的换成它——刚完成的请求的清理不能排在发出的话的 7 天后面。
  func scheduleCleanup(at wake: Date? = nil) {
    guard started else { return }
    let wake = wake ?? timing.now().addingTimeInterval(Self.retention.seconds)
    if roles.has(.cleanup), let current = cleanupWake, current <= wake { return }
    roles.cancel(.cleanup)
    cleanupWake = wake
    roles.put(.cleanup, .spawn { [timing] id in
      guard (try? await timing.sleepUntil(wake)) != nil else { return }
      let next = await self.reporting { try await self.deleteExpired() }
      self.cleanupFinished(id, next: next)
    })
  }

  /// 清理一轮；返回下一轮该在什么时候做，没有剩下的为 nil：普通的完成请求一个保留期后，发出的话与 Cue 的失败请求等到它们的 7 天到期。
  func deleteExpired() async throws -> Date? {
    let now = timing.now()
    let left = try await store.deleteCompletedDeliveries(
      before: now.addingTimeInterval(-Self.retention.seconds), claimCutoff: now.addingTimeInterval(-DeliveryRequest.phaseLimit),
      keptCutoff: now.addingTimeInterval(-Self.keptRetention))
    if left.transient { return now.addingTimeInterval(Self.retention.seconds) }
    return left.oldestKept.map { $0.addingTimeInterval(Self.keptRetention + 1) }  // 到期那一刻的判断是"晚于"，多留 1 秒
  }

  /// `next` 外层 nil 是这一轮读写失败：过一个保留期再来。
  private func cleanupFinished(_ id: UUID, next: Date??) {
    guard roles.release(.cleanup, id) else { return }
    cleanupWake = nil
    switch next {
    case .none: scheduleCleanup()
    case .some(let wake): if let wake { scheduleCleanup(at: wake) }
    }
  }
}
