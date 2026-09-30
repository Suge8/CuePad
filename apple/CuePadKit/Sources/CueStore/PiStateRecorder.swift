import Foundation

extension CueStore {
  /// 各 Pi 会话此刻的状态（含所有 Mac 写的），最近进入当前状态的在前。手机据此显示"Pi 在干什么"。
  public func piSessionStates() throws -> [PiSessionState] {
    try select(PiSessionState.self, orderBy: "stateSince DESC, id")
  }

  func writePiState(
    sessionID: String, hostID: String, title: String, projectID: UUID?, state: PiWorkState, detail: String?, stateSince: Date
  ) throws {
    try write {
      let now = Date.stamp
      let id = DeterministicID.uuid("pi-session/\(sessionID)")
      let record = PiSessionState(
        id: id, sessionID: sessionID, hostID: hostID, title: title, projectID: projectID, state: state, detail: detail,
        stateSince: stateSince, createdAt: now, modifiedAt: now)
      let assignments = PiSessionState.columns.dropFirst().filter { $0 != "createdAt" }.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
      let placeholders = PiSessionState.columns.map { _ in "?" }.joined(separator: ", ")
      try db.run(
        """
        INSERT INTO piSessionStates (\(PiSessionState.columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments)
        """, record.bindings)
    }
  }

  func deletePiState(sessionID: String) throws {
    try write { try db.run("DELETE FROM piSessionStates WHERE id = ?", [DeterministicID.uuid("pi-session/\(sessionID)")]) }
  }

  func deletePiStates(host: String) throws {
    try write { try db.run("DELETE FROM piSessionStates WHERE hostID = ?", [host]) }
  }
}

/// 把 Pi 会话的状态变化写成同步记录（每个会话一条）。
/// - 开始工作、等你确认、完成、出错：立即写；
/// - 工作中的细节变化（输出、调用哪个工具）：合并，两次写入之间至少隔 `minInterval`，期间只保留最新的一次；
/// - 与已写入内容相同的更新不再写；会话结束时删除记录并丢弃挂起的更新。
public actor PiStateRecorder {
  private struct Content: Equatable {
    var state: PiWorkState
    var detail: String?
    var title: String
    var projectID: UUID?
  }

  private struct Session {
    var observed: PiWorkState?
    var title = ""
    var projectID: UUID?
    var written: Content?
    var writtenAt: Date?
    var stateSince: Date?
    var pending: (state: PiWorkState, detail: String?)?
    var timer: Task<Void, Never>?
  }

  private let store: CueStore
  private let hostID: String
  private let minInterval: Duration
  private let timing: Timing
  private var sessions: [String: Session] = [:]

  public init(store: CueStore, hostID: String, minInterval: Duration = .seconds(5), timing: Timing = .system) {
    self.store = store
    self.hostID = hostID
    self.minInterval = minInterval
    self.timing = timing
  }

  public func update(
    sessionID: String, state: PiWorkState, detail: String? = nil, title: String? = nil, projectID: UUID? = nil
  ) async throws {
    var session = sessions[sessionID] ?? Session()
    let previous = session.observed
    session.observed = state
    if let title { session.title = title }
    if let projectID { session.projectID = projectID }
    defer { sessions[sessionID] = session }

    let content = Content(state: state, detail: detail, title: session.title, projectID: session.projectID)
    if content == session.written {
      cancelPending(&session)
      return
    }
    let startsOrEndsWork = !state.isWorking || !(previous?.isWorking ?? false)
    let now = timing.now()
    if startsOrEndsWork || session.writtenAt.map({ now.timeIntervalSince($0) >= minInterval.seconds }) ?? true {
      cancelPending(&session)
      try await write(sessionID, &session, content, at: now)
    } else {
      session.pending = (state, detail)
      if session.timer == nil, let writtenAt = session.writtenAt {
        let wait = max(0, minInterval.seconds - now.timeIntervalSince(writtenAt))
        session.timer = Task { [timing] in
          guard (try? await timing.sleep(.seconds(wait))) != nil else { return }
          await self.flush(sessionID)
        }
      }
    }
  }

  /// 会话结束：删除它的记录。
  public func end(sessionID: String) async throws {
    if var session = sessions.removeValue(forKey: sessionID) { cancelPending(&session) }
    try await store.deletePiState(sessionID: sessionID)
  }

  /// 删除这台 Mac 遗留的所有记录（App 启动时清理上次没来得及结束的会话）。
  public func reset() async throws {
    for id in Array(sessions.keys) {
      if var session = sessions.removeValue(forKey: id) { cancelPending(&session) }
    }
    try await store.deletePiStates(host: hostID)
  }

  private func flush(_ sessionID: String) async {
    guard var session = sessions[sessionID], let pending = session.pending else { return }
    session.timer = nil
    session.pending = nil
    let content = Content(state: pending.state, detail: pending.detail, title: session.title, projectID: session.projectID)
    do { try await write(sessionID, &session, content, at: timing.now()) } catch { session.pending = pending }
    if sessions[sessionID] != nil { sessions[sessionID] = session }
  }

  private func write(_ sessionID: String, _ session: inout Session, _ content: Content, at now: Date) async throws {
    let since = session.written?.state == content.state ? session.stateSince ?? now : now
    try await store.writePiState(
      sessionID: sessionID, hostID: hostID, title: content.title, projectID: content.projectID, state: content.state,
      detail: content.detail, stateSince: since)
    session.written = content
    session.writtenAt = now
    session.stateSince = since
  }

  private func cancelPending(_ session: inout Session) {
    session.timer?.cancel()
    session.timer = nil
    session.pending = nil
  }
}
