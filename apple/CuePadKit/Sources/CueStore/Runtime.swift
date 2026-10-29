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

extension PiSessionState {
  /// 保留原报告，当前断言另取投影；未知不会被当成空闲或结束。
  public var runtimeState: Open<PiWorkState> {
    if state == .known(.ended) || state == .known(.interrupted) { return state }
    return runtimeUntil == nil ? .unknown("unconfirmed") : state
  }

  /// 名册保留，过期的运行断言撤销；不捏造已交回或被中断。
  public var runtimeSubagents: [PiSubagentState] {
    guard runtimeUntil == nil else { return subagents }
    return subagents.map { agent in
      var agent = agent
      if agent.isRunning { agent.phase = .unknown("unconfirmed") }
      return agent
    }
  }
}

extension CueStore {
  /// 只有同一次系统启动的真实证明且所属 Mac 的 lease 仍有效才确认；旧报告、摘要修改时间均不能背书。
  public func runtimeIsConfirmed(_ session: PiSessionState, at now: Date = .now) throws -> Bool {
    try runtimeDeadline(session, presences: runtimePresences(), at: now) != nil
  }

  private func runtimePresences() throws -> [String: MacPresence] {
    Dictionary(try select(MacPresence.self).map { ($0.hostID, $0) }, uniquingKeysWith: { _, last in last })
  }

  private func runtimeDeadline(_ session: PiSessionState, presences: [String: MacPresence], at now: Date) -> Date? {
    guard session.state != .known(.ended), session.state != .known(.interrupted),
      let boot = session.bootID, let presence = presences[session.hostID], presence.bootID == boot,
      presence.isOnline(at: now) else { return nil }
    expire(at: presence.onlineUntil)
    return presence.onlineUntil
  }

  /// 每批只读一次 host 集合，O(S+H)；所有运行读取共用，不按会话逐条查在线状态。
  func runtimeProjection(_ sessions: [PiSessionState]) throws -> [PiSessionState] {
    guard !sessions.isEmpty else { return [] }
    let presences = try runtimePresences(), now = timing.now()
    return sessions.map { session in
      var session = session
      session.runtimeUntil = runtimeDeadline(session, presences: presences, at: now)
      return session
    }
  }

  func select(
    _ type: PiSessionState.Type, where condition: String = "1", _ arguments: [any SQLBindable] = [],
    orderBy: String = "rowid", limit: Int = -1, offset: Int = 0
  ) throws -> [PiSessionState] {
    try runtimeProjection(db.query(
      "SELECT \(PiSessionState.selection) FROM piSessionStates WHERE \(condition) ORDER BY \(orderBy) LIMIT ? OFFSET ?",
      arguments + [limit, offset]) { PiSessionState(row: $0) })
  }

  func find(_ type: PiSessionState.Type, _ id: any SQLBindable) throws -> PiSessionState? {
    try select(type, where: "id = ?", [id]).first
  }
}
