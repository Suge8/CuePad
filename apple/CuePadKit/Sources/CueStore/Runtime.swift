import Foundation
#if os(macOS)
import Darwin
#endif

/// 系统启动身份，不是 CuePad 启动身份；读取失败时不签发运行证明。
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
  /// 保留原报告，当前断言另取投影；未知不会被当成空闲或结束。所在的 Mac 不在线时也是未知，为什么在 `offlineMac`。
  public var runtimeState: Open<WorkState> {
    if state == .known(.ended) || state == .known(.interrupted) { return state }
    return runtimeUntil == nil ? .unknown("unconfirmed") : state
  }

  /// 名册保留，过期的运行断言撤销；不捏造已交回或被中断。
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
  /// 只有同一次系统启动的见证（真实报告、本机收尾或启动对账写下的 `bootID`）且所属 Mac 的 lease 仍有效才确认；旧报告、摘要修改时间均不能背书。
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

  /// Cue 的订阅也跟随运行证明与期限；lease 到期不写库，不能只盯 writeSeq。
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

  /// 每批只读一次 host 集合，O(S+H)；所有运行读取共用，不按会话逐条查在线状态。
  /// 没确认的里所在的 Mac 不在线的（没有在线记录或过了期限）带上它的名字（`offlineMac`）：说的是那台 Mac 没开，不是这个会话说不准；名字只在有这样的会话时读。
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
