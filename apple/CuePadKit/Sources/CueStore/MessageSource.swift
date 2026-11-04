import Foundation

public enum MessageSource: Equatable, Sendable {
  case user, cue, unconfirmed

  init(origin: String?) {
    switch origin {
    case nil: self = .user
    case DeliveryOrigin.cue.rawValue: self = .cue
    default: self = .unconfirmed
    }
  }
}

extension CueStore {
  /// 请求里的来源是原始事实；请求收走后由发送记录保留。没有任一记录不代表人类发起。
  public func deliverySources(among deliveries: some Sequence<UUID>) throws -> [UUID: MessageSource] {
    let ids = Set(deliveries)
    guard !ids.isEmpty else { return [:] }
    let rows = try db.query(
      """
      SELECT id, origin FROM deliveryRequests WHERE id IN (SELECT value FROM json_each(?1))
      UNION ALL
      SELECT deliveryID, origin FROM sendRecords
      WHERE deliveryID IN (SELECT value FROM json_each(?1))
        AND NOT EXISTS (SELECT 1 FROM deliveryRequests WHERE id = sendRecords.deliveryID)
      """, [Self.idList(ids)]
    ) { ($0.uuid(0), MessageSource(origin: $0.textOrNil(1))) }
    return Dictionary(rows) { first, next in first == next ? first : .unconfirmed }
  }

  /// 只给已确认的 Cue 轮签发打断凭据；没有凭据时，宿主必须在实际派发点确认空闲。
  public func cueSendContext(in sessionID: String) throws -> (deliveryID: UUID?, turnStartedAt: Date?) {
    guard let state = try sessionState(sessionID), try runtimeIsConfirmed(state, at: timing.now()),
      state.state.known?.hasPendingWork == true
    else { return (nil, nil) }
    guard let last = try select(
      PiChatMessage.self, where: "sessionID = ? AND role = '\(PiChatRole.user.rawValue)'",
      [sessionID], orderBy: "seq DESC, id DESC", limit: 1).first,
      last.source(in: try deliverySources(among: [last.deliveryID].compactMap(\.self))) == .cue
    else { return (nil, nil) }
    return (last.deliveryID, state.turnStartedAt)
  }

  /// Cue 要对会话做什么（说话、停止）之前：此刻在做什么得是确认过的，不然说不准会不会打断它、停不停得了。
  /// 所在的 Mac 不在线抛 `macOffline`，其余没确认的抛 `sessionUnconfirmed`。已结束、被打断的进程都不在，不用确认；
  /// 这台 Mac 亲手收尾的托管会话（歇着，`close`）同一次启动里照常确认。
  func requireRuntime(_ state: PiSessionState) throws {
    if state.state == .known(.ended) || state.state == .known(.interrupted) { return }
    guard state.state.known != nil, try runtimeIsConfirmed(state, at: timing.now()) else {
      if let mac = state.offlineMac { throw CueStoreError.macOffline(state.title, mac) }
      throw CueStoreError.sessionUnconfirmed(state.title)
    }
  }

  /// 进程不在的（已结束、被打断、歇着的托管会话）说一句就在后台唤醒它。
  func checkCueCanSpeak(in state: PiSessionState) throws {
    try requireRuntime(state)
    if state.state == .known(.ended) || state.state == .known(.interrupted) { return }
    if state.speakBlocked != nil {
      guard state.capabilities.contains(.speak) else { throw CueStoreError.terminalOnly(state.title) }
      throw CueStoreError.cannotSpeakNow(state.title, "在跑，CuePad 打断不了它（在终端里开的）")
    }
    guard state.state.known?.hasPendingWork == true else { return }
    switch try turnOpener(state.sessionID) {
    case .cue: return
    case .user:
      throw CueStoreError.cannotSpeakNow(state.title, "正在跑他发起的一轮，现在说会打断它")
    case .unconfirmed, nil:
      throw CueStoreError.turnSourceUnconfirmed(state.title)
    }
  }
}
