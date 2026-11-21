import Foundation
#if os(macOS)
import Darwin
#endif

public enum SystemBoot {
  public static let id: String? = {
    #if os(macOS)
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #else
    return nil
    #endif
  }()
}

extension SessionState {
  public var runtimeState: Open<WorkState> {
    if state == .known(.ended) || state == .known(.interrupted) { return state }
    return runtimeUntil == nil ? .unknown("unconfirmed") : state
  }

  public var runtimeSubagents: [SubagentState] {
    guard runtimeUntil == nil else { return subagents }
    return subagents.map { agent in
      var agent = agent
      if agent.isRunning || agent.phase == .known(.review) { agent.phase = .unknown("unconfirmed") }
      return agent
    }
  }
}

extension CueStore {
  public func runtimeIsConfirmed(_ session: SessionState, at now: Date = .now) throws -> Bool {
    try runtimeDeadline(session, presences: runtimePresences(), at: now) != nil
  }

  private func runtimePresences() throws -> [String: MacPresence] {
    Dictionary(try select(MacPresence.self).map { ($0.hostID, $0) }, uniquingKeysWith: { _, last in last })
  }

  private func runtimeDeadline(_ session: SessionState, presences: [String: MacPresence], at now: Date) -> Date? {
    guard session.state != .known(.ended), session.state != .known(.interrupted),
      let boot = session.bootID, let presence = presences[session.hostID], presence.bootID == boot,
      presence.isOnline(at: now) else { return nil }
    expire(at: presence.onlineUntil)
    return presence.onlineUntil
  }

  public func runtimeDeadlines() throws -> [Date] {
    let sessions = try runtimeProjection(db.query(
      "SELECT \(SessionState.selection) FROM piSessionStates WHERE \(WorkState.outsideSQL(WorkState.closed))"
    ) { SessionState(row: $0) })
    return Set(sessions.compactMap(\.runtimeUntil) + [try cueState()?.runtimeUntil].compactMap { $0 }).sorted()
  }

  func runtimeProjection(_ state: CueState) throws -> CueState {
    var state = state
    state.runtimeUntil = nil
    guard let host = state.hostID, host == (try cueProfile()?.activeHost), let boot = state.bootID,
      let presence = try runtimePresences()[host], presence.bootID == boot, presence.isOnline(at: timing.now()) else { return state }
    expire(at: presence.onlineUntil)
    state.runtimeUntil = presence.onlineUntil
    return state
  }

  func runtimeProjection(_ sessions: [SessionState]) throws -> [SessionState] {
    guard !sessions.isEmpty else { return [] }
    let presences = try runtimePresences(), now = timing.now()
    var names: [String: String]?
    return try sessions.map { session in
      var session = session
      session.runtimeUntil = runtimeDeadline(session, presences: presences, at: now)
      if session.runtimeUntil == nil, session.runtimeState.known == nil, presences[session.hostID]?.isOnline(at: now) != true {
        if names == nil { names = try macNames() }
        session.offlineMac = MacAgents.shownName(names?[session.hostID])
      }
      return session
    }
  }

  private func macNames() throws -> [String: String] {
    Dictionary(try db.query("SELECT hostID, name FROM macAgents WHERE name IS NOT NULL") { ($0.text(0), $0.text(1)) }) { first, _ in first }
  }

  func select(
    _ type: SessionState.Type, where condition: String = "1", _ arguments: [any SQLBindable] = [],
    orderBy: String = "rowid", limit: Int = -1, offset: Int = 0
  ) throws -> [SessionState] {
    try runtimeProjection(db.query(
      "SELECT \(SessionState.selection) FROM piSessionStates WHERE \(condition) ORDER BY \(orderBy) LIMIT ? OFFSET ?",
      arguments + [limit, offset]) { SessionState(row: $0) })
  }

  func find(_ type: SessionState.Type, _ id: any SQLBindable) throws -> SessionState? {
    try select(type, where: "id = ?", [id]).first
  }
}
