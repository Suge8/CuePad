import Foundation

public struct MacPresence: Equatable, Sendable {
  public var hostID: String
  public var onlineUntil: Date
  public var bootID: String?
  public var modifiedAt: Date

  public static let renewal: Duration = .seconds(5 * 60)
  public static let lifetime: TimeInterval = 2 * Double(renewal.components.seconds)

  func isOnline(at now: Date) -> Bool { now < onlineUntil }

  var saidGoodbye: Bool { onlineUntil <= modifiedAt }

  public static func recordID(host: String) -> UUID { DeterministicID.uuid("mac-presence/\(host)") }
}

extension MacPresence: Record, SyncedColumns {
  static let table = Table.macPresence
  static let fields: [Field] = [.plain("id"), .plain("hostID"), .plain("onlineUntil"), .plain("modifiedAt"), .plain("bootID")]
  var bindings: [any SQLBindable] { [Self.recordID(host: hostID), hostID, onlineUntil, modifiedAt, bootID] }
  init(row: Row) { self.init(hostID: row.text(1), onlineUntil: row.date(2), bootID: row.textOrNil(4), modifiedAt: row.date(3)) }
}

extension CueStore {
  @discardableResult
  public func recordMacPresence(host: String, bootID: String? = SystemBoot.id, awake: @Sendable () -> Bool) throws -> UUID {
    try write {
      let now = timing.now()
      let offline = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
      let presence = MacPresence(
        hostID: host, onlineUntil: awake() ? now.addingTimeInterval(MacPresence.lifetime) : offline, bootID: bootID, modifiedAt: Date.stamp)
      try upsert(presence, updating: ["onlineUntil", "modifiedAt", "bootID"])
      return MacPresence.recordID(host: host)
    }
  }

  public nonisolated func launchMac(
    host: String, bootID: String? = SystemBoot.id, running: @Sendable (SessionProcess) -> Bool
  ) throws -> [String: (state: WorkState, times: SessionTimes)] {
    let now = timing.now()
    return try queue!.sync {
      try assumeIsolated { store in
        let open = try store.reconcileSessionStates(host: host, bootID: bootID, running: running, at: now)
        try store.recordMacPresence(host: host, bootID: bootID) { true }
        return open
      }
    }
  }

  public func macOnlineUntil(_ host: String) throws -> Date? {
    guard let presence = try find(MacPresence.self, MacPresence.recordID(host: host)), presence.isOnline(at: timing.now()) else { return nil }
    expire(at: presence.onlineUntil)
    return presence.onlineUntil
  }

  public func macOnline(_ host: String) throws -> Bool { try macOnlineUntil(host) != nil }

  public func macKnownOff(_ host: String, at moment: Speech.Moment) throws -> String? {
    guard moment.seesPresence(of: host), try find(MacPresence.self, MacPresence.recordID(host: host))?.saidGoodbye == true else { return nil }
    return try macAgents(on: host).shownName
  }
}
