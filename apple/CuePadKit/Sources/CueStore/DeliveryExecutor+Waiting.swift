import Foundation

extension DeliveryExecutor {
  func untilDue(_ id: DeliveryRequest.ID) async throws {
    for try await expired in store.observe({ store -> Bool? in
      guard let request = try store.deliveryRequest(id) else { return nil }
      guard let due = request.dispatchDeadline else { return false }
      if store.timing.now() >= due { return true }
      store.expire(at: due)
      return false
    }) {
      guard let expired else { throw CancellationError() }
      if expired { return }
    }
    throw CancellationError()
  }

  func isDue(_ id: DeliveryRequest.ID) async throws -> Bool {
    guard let current = try await store.deliveryRequest(id) else { return true }
    return isExpired(current)
  }

  func fetch(_ keys: [String], for request: DeliveryRequest) {
    guard started, !Task.isCancelled, !fetching.has(request.id) else { return }
    fetching.put(request.id, .spawn { [fetchFile, files = store.files] id in
      let failure: ShownText?
      do {
        switch try await fetchAttachments(Set(keys), into: files, until: { try await self.untilDue(request.id) }, using: fetchFile) {
        case .arrived: failure = nil
        case .expired: failure = DeliveryPreparation.attachmentExpired
        case .missing: failure = DeliveryPreparation.attachmentMissing
        }
      } catch {
        failure = ShownText(error)
      }
      await self.fetched(request, id, failure: failure)
    })
  }

  private func fetched(_ request: DeliveryRequest, _ id: UUID, failure: ShownText?) async {
    if let failure { await finish(request, .failed(failure)) }
    guard fetching.release(request.id, id) else { return }
    enqueue()
  }

  func prepare(_ request: DeliveryRequest, _ preparation: DeliveryPreparation) async {
    guard started, !Task.isCancelled, !waiting.has(request.id),
      let stored = await reporting({ try await store.awaitDeliveryTarget(request, reason: preparation.reason) }),
      let stored, started, !Task.isCancelled else { return }
    guard stored.status == .known(.preparing) else { scheduleCleanup(); return }
    waiting.put(stored.id, .spawn { [store] id in
      do {
        let ready = try await withThrowingTaskGroup(of: Bool.self) { group in
          group.addTask { try await abandonable { try await preparation.wait() }; return true }
          group.addTask { try await self.untilDue(stored.id); return false }
          group.addTask {
            for try await needed in store.observe({ store in
              let current = try store.deliveryRequest(stored.id)
              let abandoned = try store.isDeliveryAbandoned(stored.id)
              return current?.status == .known(.preparing) && !abandoned
            }) {
              if !needed { return false }
            }
            return false
          }
          defer { group.cancelAll() }
          return try await group.next() ?? false
        }
        guard !Task.isCancelled else { return }
        try await store.abandonPreparedDeliveries(for: self.hostID)
        if try await self.isDue(stored.id) {
          await self.finish(stored, .failed(stored.expiry))
        } else if ready {
          try await store.deliveryTargetReady(stored.id)
        }
      } catch {
        if !Task.isCancelled { await self.finish(stored, .failed(ShownText(error))) }
      }
      guard self.waiting.release(stored.id, id) else { return }
      self.enqueue()
    })
  }
}
