import Foundation

extension CueStore {
  /// 有 Cue 正证据的投送：请求里的来源是原始事实，请求收走后由发送记录保留；两处说法不一或都查不到的不算。
  public func cueSentDeliveries(among deliveries: some Sequence<UUID>) throws -> Set<UUID> {
    let ids = Set(deliveries)
    guard !ids.isEmpty else { return [] }
    let rows = try db.query(
      """
      SELECT id, origin FROM deliveryRequests WHERE id IN (SELECT value FROM json_each(?1))
      UNION ALL
      SELECT deliveryID, origin FROM sendRecords
      WHERE deliveryID IN (SELECT value FROM json_each(?1))
        AND NOT EXISTS (SELECT 1 FROM deliveryRequests WHERE id = sendRecords.deliveryID)
      """, [Self.idList(ids)]
    ) { ($0.uuid(0), $0.textOrNil(1) == DeliveryOrigin.cue.rawValue) }
    return Set(Dictionary(rows) { $0 && $1 }.filter(\.value).keys)
  }

  /// Cue 要对会话做什么（说话、停止）之前：此刻在做什么得是确认过的，不然说不准会不会打断它、停不停得了。
  /// 所在的 Mac 不在线抛 `macOffline`，其余没确认的抛 `sessionUnconfirmed`。已结束、被打断的进程都不在，不用确认；
  /// 这台 Mac 亲手收尾的托管会话（歇着，`close`）同一次启动里照常确认。
  func requireRuntime(_ state: SessionState) throws {
    if state.state == .known(.ended) || state.state == .known(.interrupted) { return }
    guard state.state.known != nil, try runtimeIsConfirmed(state, at: timing.now()) else {
      if let mac = state.offlineMac { throw CueStoreError.macOffline(state.title, mac) }
      throw CueStoreError.sessionUnconfirmed(state.title)
    }
  }

  /// 进程不在的（已结束、被打断、歇着的托管会话）说一句就在后台唤醒它。
  func checkCueCanSpeak(in state: SessionState) throws {
    try requireRuntime(state)
    if state.state == .known(.ended) || state.state == .known(.interrupted) { return }
    guard state.state.known?.hasPendingWork == true else { return }
    switch state.turnOpener?.cue {
    case true: return
    case false: throw CueStoreError.cannotSpeakNow(state.title, "正在跑他发起的一轮，现在说会打断它")
    case nil: throw CueStoreError.turnSourceUnconfirmed(state.title)
    }
  }
}
