import Foundation

extension CueStore {
  /// 各 Pi 会话此刻的状态（含所有 Mac 写的），最近进入当前状态的在前。手机据此显示"Pi 在干什么"。
  public func piSessionStates() throws -> [PiSessionState] {
    try select(PiSessionState.self, orderBy: "stateSince DESC, id")
  }

  func writePiState(
    sessionID: String, hostID: String, title: String, projectID: UUID?, state: PiWorkState, detail: String?,
    notify: PiAlert?, stateSince: Date
  ) throws {
    try write {
      let now = Date.stamp
      let id = DeterministicID.uuid("pi-session/\(sessionID)")
      let record = PiSessionState(
        id: id, sessionID: sessionID, hostID: hostID, title: title, projectID: projectID, state: .known(state), detail: detail,
        notify: notify.map(Open.known), stateSince: stateSince, createdAt: now, modifiedAt: now)
      let assignments = PiSessionState.columns.dropFirst().filter { $0 != "createdAt" && $0 != "notify" }
        .map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
      let placeholders = PiSessionState.columns.map { _ in "?" }.joined(separator: ", ")
      try db.run(
        """
        INSERT INTO piSessionStates (\(PiSessionState.columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments),
          notify = CASE
            WHEN excluded.notify IS NOT NULL THEN excluded.notify
            WHEN piSessionStates.notify IS NOT NULL AND piSessionStates.state = excluded.state AND (
              NOT EXISTS (SELECT 1 FROM syncRecords s WHERE s.recordName = piSessionStates.id)
              OR piSessionStates.modifiedAt > (SELECT s.pushedModifiedAt FROM syncRecords s WHERE s.recordName = piSessionStates.id))
            THEN piSessionStates.notify
          END
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
/// - 开始工作、等你确认、完成、出错，以及会话的标题或项目变化：立即写；
/// - 工作中的细节变化（输出、调用哪个工具）：合并，两次写入之间至少隔 `minInterval`，期间只保留最新的一次；
/// - 与已写入内容相同的更新不再写；会话结束时删除记录并丢弃挂起的更新。
///
/// actor 在 await 处可重入：会话状态只在 await 之前改完，不跨 await 持有副本；落盘按决定的先后串成一条任务链，
/// 后决定的写入（含删除）不会被先决定的覆盖。
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
  private var tail: Task<Void, Never>?

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

    let content = Content(state: state, detail: detail, title: session.title, projectID: session.projectID)
    if content == session.written {
      cancelPending(&session)
      sessions[sessionID] = session
      return
    }
    let startsOrEndsWork = !state.isWorking || !(previous?.isWorking ?? false)
    let renamed = session.written.map { $0.title != content.title || $0.projectID != content.projectID } ?? true
    let now = timing.now()
    guard startsOrEndsWork || renamed || session.writtenAt.map({ now.timeIntervalSince($0) >= minInterval.seconds }) ?? true else {
      session.pending = (state, detail)
      if session.timer == nil, let writtenAt = session.writtenAt {
        let wait = max(0, minInterval.seconds - now.timeIntervalSince(writtenAt))
        session.timer = Task { [timing] in
          guard (try? await timing.sleep(.seconds(wait))) != nil else { return }
          await self.flush(sessionID)
        }
      }
      sessions[sessionID] = session
      return
    }
    cancelPending(&session)
    let write = commit(sessionID, &session, content, notify: Self.alert(entering: state, from: previous), at: now)
    sessions[sessionID] = session
    do { try await persist(write) } catch {
      forgetWritten(sessionID, content)
      throw error
    }
  }

  /// 会话结束：删除它的记录。
  public func end(sessionID: String) async throws {
    if var session = sessions.removeValue(forKey: sessionID) { cancelPending(&session) }
    try await persist { [store] in try await store.deletePiState(sessionID: sessionID) }
  }

  /// 删除这台 Mac 遗留的所有记录（App 启动时清理上次没来得及结束的会话）。
  public func reset() async throws {
    for id in Array(sessions.keys) {
      if var session = sessions.removeValue(forKey: id) { cancelPending(&session) }
    }
    try await persist { [store, hostID] in try await store.deletePiStates(host: hostID) }
  }

  private func flush(_ sessionID: String) async {
    guard var session = sessions[sessionID], let pending = session.pending else { return }
    session.timer = nil
    session.pending = nil
    let content = Content(state: pending.state, detail: pending.detail, title: session.title, projectID: session.projectID)
    let write = commit(sessionID, &session, content, at: timing.now())
    sessions[sessionID] = session
    // 定时写入没有调用方可报告；记为未写入，下一次更新会重写
    do { try await persist(write) } catch { forgetWritten(sessionID, content) }
  }

  /// 手机通知只发两种转换：进入等你确认；从工作中进入完成。首次看到的会话（没有上一个状态）不通知，
  /// 这样重启后重新登记已有会话不会把旧事件再推一遍。
  /// 标志置位后，同一状态下的后续写入（如仍在等、只换了问题文本）在标志上传之前沿用它（见 `writePiState`），
  /// 上传之后的同状态写入不再带标志，订阅不会为同一次等待重复通知。状态一旦前进（如用户答完回到思考中），
  /// 未上传的标志随之作废——已恢复工作的会话不该再提示"等你确认"。会话结束（`end`）删除记录，未上传的标志也随之丢失。
  private static func alert(entering state: PiWorkState, from previous: PiWorkState?) -> PiAlert? {
    guard let previous else { return nil }
    if state == .waitingForUser, previous != .waitingForUser { return .waitingForUser }
    if state == .settled, previous.isWorking { return .settled }
    return nil
  }

  /// 把 `content` 记为已写入，返回对应的落盘操作。
  private func commit(
    _ sessionID: String, _ session: inout Session, _ content: Content, notify: PiAlert? = nil, at now: Date
  ) -> @Sendable () async throws -> Void {
    let since = session.written?.state == content.state ? session.stateSince ?? now : now
    session.written = content
    session.writtenAt = now
    session.stateSince = since
    return { [store, hostID] in
      try await store.writePiState(
        sessionID: sessionID, hostID: hostID, title: content.title, projectID: content.projectID, state: content.state,
        detail: content.detail, notify: notify, stateSince: since)
    }
  }

  /// 按决定的先后落盘：排在此前所有写入之后。
  private func persist(_ write: @escaping @Sendable () async throws -> Void) async throws {
    let previous = tail
    let task = Task {
      await previous?.value
      try await write()
    }
    tail = Task { _ = await task.result }
    try await task.value
  }

  /// 落盘失败：只要之后没有更新的写入，就当作没写过，下一次更新不会被去重跳过。
  private func forgetWritten(_ sessionID: String, _ content: Content) {
    if sessions[sessionID]?.written == content { sessions[sessionID]?.written = nil }
  }

  private func cancelPending(_ session: inout Session) {
    session.timer?.cancel()
    session.timer = nil
    session.pending = nil
  }
}
