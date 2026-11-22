import Foundation

extension CueStore {
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

  func requireRuntime(_ state: SessionState) throws {
    if state.state == .known(.ended) || state.state == .known(.interrupted) { return }
    guard state.state.known != nil, try runtimeIsConfirmed(state, at: timing.now()) else {
      if let mac = state.offlineMac { throw CueStoreError.macOffline(state.title, mac) }
      throw CueStoreError.sessionUnconfirmed(state.title)
    }
  }

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
