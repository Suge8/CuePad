import Foundation

extension CueStore {
  /// 会话列表的一页（Mac 与手机共用的唯一查询）。顺序见 `PiSessionPage`。
  public func piSessionPage(_ query: PiSessionQuery) throws -> PiSessionPage {
    var conditions: [String] = []
    var arguments: [any SQLBindable] = []
    switch query.scope {
    case .live: conditions.append("state != '\(PiWorkState.ended.rawValue)'")
    case .ended: conditions.append("state = '\(PiWorkState.ended.rawValue)'")
    case .all: break
    }
    if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_") + "%"
      conditions.append("(title LIKE ? ESCAPE '\\' OR folder LIKE ? ESCAPE '\\' OR lastPrompt LIKE ? ESCAPE '\\')")
      arguments += [pattern, pattern, pattern]
    }
    if let project = query.project {
      conditions.append("projectID = ?")
      arguments.append(project)
    }
    if let token = query.launchToken {
      conditions.append("launchToken = ?")
      arguments.append(token)
    }
    if let id = query.id {
      conditions.append("id = ?")
      arguments.append(id)
    }
    let condition = conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
    let states = try select(
      PiSessionState.self, where: condition, arguments, orderBy: "state = 'ended', stateSince DESC, id",
      limit: query.limit, offset: query.offset)
    let total = try db.first("SELECT count(*) FROM piSessionStates WHERE \(condition)", arguments) { Int($0.int(0)) } ?? 0
    let projects = Dictionary(uniqueKeysWithValues: try self.projects().map { ($0.id, $0) })
    return PiSessionPage(items: states.map { PiSessionListItem(state: $0, project: $0.projectID.flatMap { projects[$0] }) }, total: total)
  }

  func writePiState(
    sessionID: String, hostID: String, title: String, folder: String?, projectID: UUID?, state: PiWorkState, detail: String?,
    recap: PiRecap, notify: PiAlert?, times: PiTimes, launchToken: String?, hosted: Bool, subagents: [PiSubagentState]
  ) throws {
    try write {
      let now = Date.stamp
      let record = PiSessionState(
        id: PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, hostID: hostID, title: title, projectID: projectID,
        state: .known(state), detail: detail, folder: folder, lastPrompt: recap.lastPrompt, lastReply: recap.lastReply,
        question: recap.question, notify: notify.map(Open.known), stateSince: times.stateSince, busySince: times.busySince,
        createdAt: now, modifiedAt: now, launchToken: launchToken, hosted: hosted, subagents: subagents)
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

  /// 把这台 Mac 的会话记为已结束（`sessionID` 为 nil 时是它全部未结束的会话），近况留着。
  func endPiStates(host: String, sessionID: String?, at now: Date) throws {
    try write {
      let ended = PiWorkState.ended.rawValue
      let end = """
        UPDATE piSessionStates SET state = ?, detail = NULL, question = NULL, notify = NULL, stateSince = ?, busySince = NULL,
          hosted = NULL, subagents = NULL,
          modifiedAt = ?
        """
      if let sessionID {
        try db.run("\(end) WHERE id = ? AND state != ?", [ended, now, Date.stamp, PiSessionState.recordID(sessionID: sessionID), ended])
      } else {
        try db.run("\(end) WHERE hostID = ? AND state != ?", [ended, now, Date.stamp, host, ended])
      }
    }
  }
}

/// 把 Pi 会话的状态变化写成同步记录（每个会话一条）。
/// - 开始工作、等你确认、完成、出错，以及会话的标题或项目变化：立即写；
/// - 工作中的细节变化（输出、调用哪个工具）：合并，两次写入之间至少隔 `minInterval`，期间只保留最新的一次；
/// - 近况（`PiRecap`）变化：立即写；
/// - 与已写入内容相同的更新不再写；会话结束时把记录标为已结束（近况留给手机看，记录与会话文件同存亡，
///   见 `CueStore.retainPiSessions`）并丢弃挂起的更新。
///
/// actor 在 await 处可重入：会话状态只在 await 之前改完，不跨 await 持有副本；落盘按决定的先后串成一条任务链，
/// 后决定的写入（含删除）不会被先决定的覆盖。
public actor PiStateRecorder {
  private struct Content: Equatable {
    var state: PiWorkState
    var detail: String?
    var title: String
    var folder: String?
    var projectID: UUID?
    var recap: PiRecap
    var times: PiTimes
    var launchToken: String?
    var hosted: Bool
    var subagents: [PiSubagentState]
  }

  private struct Session {
    var observed: PiWorkState?
    var title = ""
    var folder: String?
    var projectID: UUID?
    var recap = PiRecap()
    var launchToken: String?
    var hosted = false
    var subagents: [PiSubagentState] = []
    /// 调用方给的计时基准；没给过时（测试、演示）用第一次写入的时间，之后不变
    var times: PiTimes?
    var written: Content?
    var writtenAt: Date?
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
    sessionID: String, state: PiWorkState, detail: String? = nil, title: String? = nil, folder: String? = nil,
    projectID: UUID? = nil, recap: PiRecap? = nil, times: PiTimes? = nil, launchToken: String? = nil, hosted: Bool? = nil,
    subagents: [PiSubagentState]? = nil
  ) async throws {
    var session = sessions[sessionID] ?? Session()
    let previous = session.observed
    session.observed = state
    if let title { session.title = title }
    if let folder { session.folder = folder }
    if let projectID { session.projectID = projectID }
    if let recap { session.recap = recap }
    if let launchToken { session.launchToken = launchToken }
    if let hosted { session.hosted = hosted }
    if let subagents { session.subagents = subagents }
    let now = timing.now()
    let times = times ?? session.times ?? PiTimes(stateSince: now, busySince: nil)
    session.times = times

    let content = Content(
      state: state, detail: detail, title: session.title, folder: session.folder, projectID: session.projectID, recap: session.recap,
      times: times, launchToken: session.launchToken, hosted: session.hosted, subagents: session.subagents)
    if content == session.written {
      cancelPending(&session)
      sessions[sessionID] = session
      return
    }
    let startsOrEndsWork = !state.isWorking || !(previous?.isWorking ?? false)
    let renamed = session.written.map {
      $0.title != content.title || $0.folder != content.folder || $0.projectID != content.projectID || $0.recap != content.recap
        || $0.hosted != content.hosted || $0.subagents != content.subagents
        || $0.times != content.times
    } ?? true
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

  /// 会话结束：记录标为已结束。
  public func end(sessionID: String) async throws {
    if var session = sessions.removeValue(forKey: sessionID) { cancelPending(&session) }
    try await endRecords(sessionID: sessionID)
  }

  /// 这台 Mac 遗留的记录都标为已结束（App 启动时：上次没来得及结束的会话；还活着的会重新登记）。
  public func reset() async throws {
    for id in Array(sessions.keys) {
      if var session = sessions.removeValue(forKey: id) { cancelPending(&session) }
    }
    try await endRecords(sessionID: nil)
  }

  private func endRecords(sessionID: String?) async throws {
    let now = timing.now()
    try await persist { [store, hostID] in try await store.endPiStates(host: hostID, sessionID: sessionID, at: now) }
  }

  private func flush(_ sessionID: String) async {
    guard var session = sessions[sessionID], let pending = session.pending, let times = session.times else { return }
    session.timer = nil
    session.pending = nil
    let content = Content(
      state: pending.state, detail: pending.detail, title: session.title, folder: session.folder, projectID: session.projectID,
      recap: session.recap, times: times, launchToken: session.launchToken, hosted: session.hosted,
      subagents: session.subagents)
    let write = commit(sessionID, &session, content, at: timing.now())
    sessions[sessionID] = session
    // 定时写入没有调用方可报告；记为未写入，下一次更新会重写
    do { try await persist(write) } catch { forgetWritten(sessionID, content) }
  }

  /// 手机通知只发两种转换：进入等你确认；从工作中进入完成。首次看到的会话（没有上一个状态）不通知，
  /// 这样重启后重新登记已有会话不会把旧事件再推一遍。
  /// 标志置位后，同一状态下的后续写入（如仍在等、只换了问题文本）在标志上传之前沿用它（见 `writePiState`），
  /// 上传之后的同状态写入不再带标志，订阅不会为同一次等待重复通知。状态一旦前进（如用户答完回到思考中），
  /// 未上传的标志随之作废——已恢复工作的会话不该再提示"等你确认"。会话结束（`end`）清掉标志，未上传的也不再通知。
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
    session.written = content
    session.writtenAt = now
    return { [store, hostID] in
      try await store.writePiState(
        sessionID: sessionID, hostID: hostID, title: content.title, folder: content.folder, projectID: content.projectID,
        state: content.state, detail: content.detail, recap: content.recap, notify: notify, times: content.times,
        launchToken: content.launchToken, hosted: content.hosted, subagents: content.subagents)
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
