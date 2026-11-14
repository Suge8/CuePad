import Foundation

extension CueStore {
  /// 要等人或等证据的请求留多久（`removableAt`），与对话的保留期一样是 7 天；其余留 `DeliveryExecutor.retention`。
  static let keptRetention: TimeInterval = 7 * 86_400

  /// 删掉到了保留期的投送请求（`removableAt`），返回下一条到期的时刻，没有为 nil。`now` 是调用方的钟，缺省是库的。
  /// 没收尾的请求（没领的、领了没结果的）只有执行的那台的库说了算：别的设备的库可能是旧的（离线一阵，那台其间领过、办完了），
  /// 删了会连那台写下的结局一起删掉（本机删除压过后到的远端版本）。所以它们只在是 `host` 的（执行器自己的），
  /// 或本机刚完整拉过一遍服务器时删，且只删 `pulledAt`（那一拉开始的时刻）之前就到期的；发往再也不上线的 Mac 的由别的设备这样清掉（`AppServices.startDeliveryCleanup`）。
  @discardableResult
  public func deleteExpiredDeliveries(at now: Date? = nil, host: String? = nil, pulledAt: Date? = nil) throws -> Date? {
    try write { try removeExpiredDeliveries(among: nil, at: now ?? timing.now(), host: host, pulledAt: pulledAt) }
  }

  /// `among` 只看这几条（发出的话的消息刚上了服务器，`markPushed`）。必须在写事务内调用。
  @discardableResult
  func removeExpiredDeliveries(among ids: Set<UUID>?, at now: Date, host: String? = nil, pulledAt: Date? = nil) throws -> Date? {
    if ids?.isEmpty == true { return nil }
    let requests = if let ids {
      try select(DeliveryRequest.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
    } else {
      try select(DeliveryRequest.self)
    }
    var removable: [UUID] = [], next: Date?
    for request in requests {
      guard let at = try removableAt(request) else { continue }
      var until = now
      if request.hostID != host, request.status.known.map(DeliveryStatus.open.contains) != false {
        guard let pulledAt else { continue }
        until = min(now, pulledAt)
      }
      if at <= until { removable.append(request.id) } else { next = min(next ?? at, at) }
    }
    if !removable.isEmpty { try db.run("DELETE FROM deliveryRequests WHERE id IN (SELECT value FROM json_each(?))", [Self.idList(removable)]) }
    return next
  }

  /// 投送请求什么时候可以删，只此一处；nil 是没有时间上限（不认识的状态）。都从记录上的时刻算，不因重启或同步续期，超窗只删请求、不改关联修订。
  /// - 没人领的：派发期限再过 7 天（执行的 Mac 那时早已不会领取它，钟差也远小于这段）；领了没收尾的：执行期限再过 7 天（那台 Mac 再没回来）。
  /// - 发出的话：消息上了服务器、原关联已解决就收走（之前由消息接替气泡），否则留 7 天；撤回、没能送达的话、没开成的会话、未确认的、Cue 的失败请求留 7 天：等重发、正证据对账、Cue 来看（`cueChanges`）。
  /// - 开成的会话：等认领（`claimLaunchedCards`）与原关联最多一个派发阶段；没在等的一个保留期。其余一个保留期。
  private func removableAt(_ request: DeliveryRequest) throws -> Date? {
    guard let status = request.status.known else { return nil }
    let kept = Self.keptRetention, short = DeliveryExecutor.retention.seconds
    switch status {
    case .pending, .preparing: return request.dispatchDeadline?.addingTimeInterval(kept)
    case .executing, .confirming: return request.deadlineAt?.addingTimeInterval(kept)
    case .succeeded, .failed, .unconfirmed: break
    }
    guard let completed = request.completedAt else { return nil }
    let mode = request.mode.known, origin = request.origin
    switch status {
    case .unconfirmed: return completed.addingTimeInterval(kept)
    case .failed:
      let keep = mode == .send || mode == .withdraw || mode == .start || origin == .known(.cue)
      return completed.addingTimeInterval(keep ? kept : short)
    default: break
    }
    switch mode {
    case .send:
      if try messageUploaded(request.id), try sessionBindingDisposition(request) == .settled { return completed }
      return completed.addingTimeInterval(kept)
    case .withdraw: return completed.addingTimeInterval(kept)
    case .start:
      if try !awaitsClaim(request), try sessionBindingDisposition(request) == .settled { return completed.addingTimeInterval(short) }
      return completed.addingTimeInterval(DeliveryRequest.phaseLimit)
    default: return completed.addingTimeInterval(short)
    }
  }

  private func messageUploaded(_ id: UUID) throws -> Bool {
    try db.first("""
      SELECT 1 FROM piMessages m JOIN syncRecords s ON s.recordName = m.id WHERE m.deliveryID = ? AND s.pushedModifiedAt IS NOT NULL
      """, [id]) { _ in true } ?? false
  }

  /// 带着灵感或任务开成的会话，是这件事最新的一次交接、会话记录还没带着它的认领标识到。
  private func awaitsClaim(_ request: DeliveryRequest) throws -> Bool {
    guard request.cardID != nil else { return false }
    return try db.first("""
      SELECT 1 FROM deliveryRequests WHERE id = ? AND \(Self.latestHandoff("deliveryRequests")) AND \(Self.launchUnclaimed)
      """, [request.id]) { _ in true } ?? false
  }

  /// 永久删除原卡同时解除请求的关联引用；删除事实无需另存，后续回执只记送达。
  func releaseDeliveryBindings(of cards: [UUID]) throws {
    guard !cards.isEmpty else { return }
    try db.run("""
      UPDATE deliveryRequests SET cardID = NULL, sessionBindingRevision = NULL, modifiedAt = ?
      WHERE cardID IN (SELECT value FROM json_each(?))
      """, [Date.stamp, Self.idList(cards)])
  }
}
