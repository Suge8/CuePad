import Foundation

extension DeliveryExecutor {
  func scheduleCleanup(at wake: Date? = nil) {
    guard started else { return }
    let wake = wake ?? timing.now().addingTimeInterval(Self.retention.seconds)
    if roles.has(.cleanup), let current = cleanupWake, current <= wake { return }
    roles.cancel(.cleanup)
    cleanupWake = wake
    roles.put(.cleanup, .spawn { [timing, store, hostID] id in
      guard (try? await timing.sleepUntil(wake)) != nil else { return }
      let next = await self.reporting { try await store.deleteExpiredDeliveries(at: timing.now(), host: hostID) }
      self.cleanupFinished(id, next: next)
    })
  }

  private func cleanupFinished(_ id: UUID, next: Date??) {
    guard roles.release(.cleanup, id) else { return }
    cleanupWake = nil
    switch next {
    case .none: scheduleCleanup()
    case .some(let wake): if let wake { scheduleCleanup(at: wake) }
    }
  }
}
