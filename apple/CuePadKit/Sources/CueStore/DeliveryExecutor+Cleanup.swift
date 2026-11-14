import Foundation

extension DeliveryExecutor {
  /// 在 `wake`（缺省是保留期后）清理一轮；已排了不晚于它的就不动，更晚的换成它——刚完成的请求的清理不能排在发出的话的 7 天后面。
  func scheduleCleanup(at wake: Date? = nil) {
    guard started else { return }
    let wake = wake ?? timing.now().addingTimeInterval(Self.retention.seconds)
    if roles.has(.cleanup), let current = cleanupWake, current <= wake { return }
    roles.cancel(.cleanup)
    cleanupWake = wake
    roles.put(.cleanup, .spawn { [timing, store] id in
      guard (try? await timing.sleepUntil(wake)) != nil else { return }
      let next = await self.reporting { try await store.deleteExpiredDeliveries(at: timing.now()) }
      self.cleanupFinished(id, next: next)
    })
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
