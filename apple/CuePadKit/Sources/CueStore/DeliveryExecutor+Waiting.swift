import Foundation

/// 缺前提时在旁边等（`DeliveryExecutor` 头注释）：取附件、等现有会话就绪。两种等待都不抓一份期限，到点从库里重读这条请求的派发期限
/// （`untilDue`）：锚点只有一个（`DeliveryRequest.dispatchDeadline`），期限监视、SQL 与这里读的是同一份。
extension DeliveryExecutor {
  /// 订阅同一份派发期限；锚点尚未落定就等它，删除则取消等待，不能把两者当作到期。
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

  /// 库里这条的派发期限已到（不在了算到了）。
  func isDue(_ id: DeliveryRequest.ID) async throws -> Bool {
    guard let current = try await store.deliveryRequest(id) else { return true }
    return isExpired(current)
  }

  /// 在旁边把这条请求的附件取齐，至迟到派发期限：取到了再过一遍队列（文件不在库里，库的变化叫不醒执行器），取不来、取过了仍不在、到期都按失败写回。
  /// 等附件时请求仍是 `pending`：`preparing` 只许等现有会话、不许唤醒（`MacDeliveryPreparation`），等附件不该带上这条限制。
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
    // 先写回再让位：位置空出来之后期限监视才会接手，不抢着写没有原因的到期
    if let failure { await finish(request, .failed(failure)) }
    guard fetching.release(request.id, id) else { return }  // 停下了
    enqueue()
  }

  func prepare(_ request: DeliveryRequest, _ preparation: DeliveryPreparation) async {
    guard started, !Task.isCancelled, !waiting.has(request.id),
      let stored = await reporting({ try await store.awaitDeliveryTarget(request, reason: preparation.reason) }),
      let stored, started, !Task.isCancelled else { return }
    notifyWritten(stored.id)
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
              return current?.status == .known(.preparing) && current?.handledBy == nil && !abandoned
            }) {
              if !needed { return false }
            }
            return false
          }
          defer { group.cancelAll() }
          return try await group.next() ?? false
        }
        guard !Task.isCancelled else { return }
        for id in try await store.abandonPreparedDeliveries(for: self.hostID) { self.notifyWritten(id) }
        if try await self.isDue(stored.id) {
          await self.finish(stored, .failed(stored.expiry))
        } else if ready {
          try await store.deliveryTargetReady(stored.id)
          self.notifyWritten(stored.id)
        }
      } catch {
        if !Task.isCancelled { await self.finish(stored, .failed(ShownText(error))) }
      }
      guard self.waiting.release(stored.id, id) else { return }
      self.enqueue()
    })
  }
}
