import Foundation

extension CueStore {
  func writePiState(sessionID: String, hostID: String, content: PiStateContent, notify: PiAlert?) throws {
    try write {
      let now = Date.stamp
      let record = PiSessionState(
        id: PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, hostID: hostID, title: content.title,
        projectID: content.projectID, state: .known(content.state), detail: content.detail, folder: content.folder, lastPrompt: nil,
        lastReply: nil, question: content.question, notify: notify.map(Open.known), stateSince: content.times.stateSince,
        busySince: content.times.busySince, createdAt: now, modifiedAt: now, launchToken: content.launchToken, hosted: content.hosted,
        subagents: content.subagents, model: content.modelState.model, thinking: content.modelState.thinking,
        models: content.modelState.models, context: content.context, commands: content.commands, agent: .known(content.agent))
      // 摘要不归这里写：它是对话的投影，只由 `writePiTranscript` 写（新记录插入时先空着）
      let assignments = PiSessionState.columns.dropFirst()
        .filter { $0 != "createdAt" && $0 != "notify" && !PiSessionState.recapColumns.contains($0) }
        .map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
      let placeholders = PiSessionState.columns.map { _ in "?" }.joined(separator: ", ")
      try db.run(
        """
        INSERT INTO piSessionStates (\(PiSessionState.columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments),
          notify = CASE
            WHEN excluded.notify IS NOT NULL THEN excluded.notify
            WHEN piSessionStates.notify IS NOT NULL AND piSessionStates.state = excluded.state THEN piSessionStates.notify
          END
        """, record.bindings)
      if content.launchToken != nil { try claimLaunchedCards() }
    }
  }

  /// 把这台 Mac 的会话记为已结束，近况留着。`sessionID` 为 nil 时是启动对账：上次没来得及结束的会话都记为已结束，
  /// 只有托管着的（进程随上次退出而歇下，仍可唤醒）改记为歇着、不进历史。
  func endPiStates(host: String, sessionID: String?, at now: Date) throws {
    try write {
      let ended = PiWorkState.ended.rawValue
      let end = """
        UPDATE piSessionStates SET state = ?, detail = NULL, question = NULL, notify = NULL, stateSince = ?, busySince = NULL,
          hosted = NULL, subagents = NULL, models = NULL, commands = NULL,
          modifiedAt = ?
        """
      if let sessionID {
        try db.run("\(end) WHERE id = ? AND state != ?", [ended, now, Date.stamp, PiSessionState.recordID(sessionID: sessionID), ended])
      } else {
        try db.run("\(end) WHERE hostID = ? AND state != ? AND hosted IS NULL", [ended, now, Date.stamp, host, ended])
        try rest(host: host, sessionID: nil, at: now)
      }
    }
  }

  /// 托管的会话进程退出后的样子（见 `rest`），在一个写事务里提交并发布变更。
  func restPiStates(host: String, sessionID: String, at now: Date) throws {
    try write { try rest(host: host, sessionID: sessionID, at: now) }
  }

  /// 托管的会话进程退出后的样子：记录留着、托管标记留着（进程不在），歇着——没有在做的事、没有问题、没有通知。
  /// 已经歇着的不动起点（"多久前"仍从它歇下算起）；已结束的不碰，所以与用户结束会话写的已结束先后不论。
  private func rest(host: String, sessionID: String?, at now: Date) throws {
    let rest = """
      UPDATE piSessionStates SET stateSince = CASE WHEN state = ? THEN stateSince ELSE ? END, state = ?, detail = NULL, question = NULL,
        notify = NULL, busySince = NULL, subagents = NULL, models = NULL, commands = NULL, modifiedAt = ?
      WHERE hosted = 1 AND state != ?
      """
    let head: [any SQLBindable] = [PiWorkState.settled.rawValue, now, PiWorkState.settled.rawValue, Date.stamp, PiWorkState.ended.rawValue]
    if let sessionID {
      try db.run("\(rest) AND id = ?", head + [PiSessionState.recordID(sessionID: sessionID)])
    } else {
      try db.run("\(rest) AND hostID = ?", head + [host])
    }
  }

  /// 删掉这台 Mac 上歇着的托管会话里没有会话文件索引的记录（文件被删的、从没落盘的）；`live` 是此刻在线的会话，不动。
  func deleteUnindexedHostedStates(host: String, except live: Set<String>) throws {
    let refs = live.isEmpty ? "" : "AND sessionID NOT IN (\(Array(repeating: "?", count: live.count).joined(separator: ", ")))"
    var arguments: [any SQLBindable] = [host, PiWorkState.ended.rawValue]
    arguments += live.sorted().map { $0 as any SQLBindable }
    try write {
      try db.run(
        "DELETE FROM piSessionStates WHERE hostID = ? AND hosted = 1 AND state != ? AND sessionID NOT IN (SELECT id FROM piSessions) \(refs)",
        arguments)
    }
  }

  /// 删掉一个会话的记录（同步删除）：会话结束时没有留下会话文件的，不进历史。
  func deletePiState(sessionID: String) throws {
    try write { try db.run("DELETE FROM piSessionStates WHERE id = ?", [PiSessionState.recordID(sessionID: sessionID)]) }
  }
}

/// 会话记录上由 Pi 桥与记录器写的全部字段（摘要不在其中）：会话的当前值、已写入的值与落盘用的是同一个形状。
struct PiStateContent: Equatable, Sendable {
  var state: PiWorkState
  var detail: String?
  var title = ""
  var folder: String?
  var projectID: UUID?
  var question: PiQuestion?
  var times: PiTimes
  var launchToken: String?
  var hosted = false
  var subagents: [PiSubagentState] = []
  var modelState = PiModelState()
  var context: PiContextUsage?
  var commands: [PiSlashCommand] = []
  var agent = AgentKind.pi

  /// 去掉随每次工具调用不断变的细节（状态、说明、子代理的动作、上下文用量、认领标识）的样子：它变了才值得绕开写入节流。
  var steady: PiStateContent {
    var steady = self
    steady.state = .settled
    steady.detail = nil
    steady.launchToken = nil
    steady.context = nil
    steady.subagents = subagents.map(\.shape)
    return steady
  }
}

/// 把 Pi 会话的状态变化写成同步记录（每个会话一条）。
/// - 开始工作、等你确认、完成、出错，以及会话的标题或项目变化：立即写；
/// - 工作中的细节变化（输出、调用哪个工具）：合并，两次写入之间至少隔 `minInterval`，期间只保留最新的一次；
/// - 近况（`PiRecap`）变化：立即写；
/// - 与已写入内容相同的更新不再写；会话的进程退出时按 `exited` 处理记录（历史、歇着、删除）并丢弃挂起的更新；用户结束会话时
///   标为已结束（近况留给手机看，记录与会话文件同存亡，见 `CueStore.retainPiSessions`）。
///
/// actor 在 await 处可重入：会话状态只在 await 之前改完，不跨 await 持有副本；落盘按决定的先后串成一条任务链，
/// 后决定的写入（含删除）不会被先决定的覆盖。
public actor PiStateRecorder {
  private struct Session {
    /// 最近一次更新给出的全部字段；没给过时（还没有更新）为 nil
    var content: PiStateContent?
    var written: PiStateContent?
    var writtenAt: Date?
    /// 有挂起的更新（节流期内只保留最新一次，就是 `content`）时在等的定时写入
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

  /// 没给的字段（nil）沿用上一次的值；`question` 与 `detail` 每次整体替换。
  /// 返回这次写入置位的通知标志（没有置位为 nil）：调用方据此立即上传这一条，通知不等引擎的自动调度。
  @discardableResult
  public func update(
    sessionID: String, state: PiWorkState, detail: String? = nil, title: String? = nil, folder: String? = nil,
    projectID: UUID? = nil, question: PiQuestion? = nil, times: PiTimes? = nil, launchToken: String? = nil, hosted: Bool? = nil,
    subagents: [PiSubagentState]? = nil, modelState: PiModelState? = nil, context: PiContextUsage? = nil, commands: [PiSlashCommand]? = nil,
    agent: AgentKind? = nil
  ) async throws -> PiAlert? {
    var session = sessions[sessionID] ?? Session()
    let now = timing.now()
    let previous = session.content.map { (state: $0.state, since: $0.times.stateSince) }
    // 调用方给的计时基准；没给过时（测试、演示）用第一次写入的时间，之后不变
    var content = session.content ?? PiStateContent(state: state, times: PiTimes(stateSince: now, busySince: nil))
    content.state = state
    content.detail = detail
    content.question = question
    if let title { content.title = title }
    if let folder { content.folder = folder }
    if let projectID { content.projectID = projectID }
    if let times { content.times = times }
    if let launchToken { content.launchToken = launchToken }
    if let hosted { content.hosted = hosted }
    if let subagents { content.subagents = subagents }
    if let modelState { content.modelState = modelState }
    if let context { content.context = context }
    if let commands { content.commands = commands }
    if let agent { content.agent = agent }
    // 工作中总有这段连续处理的起点（界面的"已运行"、停止的进度都从它算）：桥上的会话由扩展给，
    // 不带时间的调用方（演示、测试）从进入工作算
    if state.isWorking, content.times.busySince == nil { content.times.busySince = content.times.stateSince }
    session.content = content

    if content == session.written {
      cancelPending(&session)
      sessions[sessionID] = session
      return nil
    }
    let startsOrEndsWork = !state.isWorking || !(previous?.state.isWorking ?? false)
    let changed = session.written.map { $0.steady != content.steady } ?? true
    guard startsOrEndsWork || changed || session.writtenAt.map({ now.timeIntervalSince($0) >= minInterval.seconds }) ?? true else {
      if session.timer == nil, let writtenAt = session.writtenAt {
        let wait = max(0, minInterval.seconds - now.timeIntervalSince(writtenAt))
        session.timer = Task { [timing] in
          guard (try? await timing.sleep(.seconds(wait))) != nil else { return }
          await self.flush(sessionID)
        }
      }
      sessions[sessionID] = session
      return nil
    }
    cancelPending(&session)
    let alert = PiAlert.entering(state, since: content.times.stateSince, from: previous)
    let write = commit(sessionID, &session, content, notify: alert, at: now)
    sessions[sessionID] = session
    do { try await persist(write) } catch {
      forgetWritten(sessionID, content)
      throw error
    }
    return alert
  }

  /// 会话结束：记录标为已结束（用户在 CuePad 里结束会话、终端里的 Pi 退出），进历史。
  public func end(sessionID: String) async throws {
    if var session = sessions.removeValue(forKey: sessionID) { cancelPending(&session) }
    try await endRecords(sessionID: sessionID)
  }

  /// 启动对账（历史回填完成后）：歇着的托管会话没有会话文件索引的（文件被删的、从没落盘的）删掉记录；此刻在线的（本记录器正在跟的）不动——
  /// 它们的记录由状态变化自己写，对账与写入在这里排在同一条任务链上，不会删掉刚建立的会话。
  public func dropUnindexedHosted() async throws {
    let live = Set(sessions.keys)
    try await persist { [store, hostID] in try await store.deleteUnindexedHostedStates(host: hostID, except: live) }
  }

  /// 会话的进程退出了、没有别的进程接着它：什么算历史只在这里定——
  /// - 没留下对话的（`spoke` 为 false：Pi 在第一条消息落盘前不建文件，`--no-session` 也没有）：一句话没说过，不进历史，记录删掉（同步删除）；
  /// - CuePad 后台托管的：闲置退出不算结束，记录留着、歇着，仍在"现在"，发话由本机执行器照常唤醒；
  /// - 其余（终端里的 Pi 退出）：记为已结束，进历史。
  /// 托管的会话要结束，由用户的结束请求写 `end`。
  public func exited(sessionID: String, spoke: Bool, hosted: Bool) async throws {
    if var session = sessions.removeValue(forKey: sessionID) { cancelPending(&session) }
    let id = sessionID
    let now = timing.now()
    if !spoke {
      try await persist { [store] in try await store.deletePiState(sessionID: id) }
    } else if hosted {
      try await persist { [store, hostID] in try await store.restPiStates(host: hostID, sessionID: id, at: now) }
    } else {
      try await endRecords(sessionID: id)
    }
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
    guard var session = sessions[sessionID], session.timer != nil, let content = session.content else { return }
    session.timer = nil
    let write = commit(sessionID, &session, content, at: timing.now())
    sessions[sessionID] = session
    // 定时写入没有调用方可报告；记为未写入，下一次更新会重写
    do { try await persist(write) } catch { forgetWritten(sessionID, content) }
  }

  /// 把 `content` 记为已写入，返回对应的落盘操作。`notify` 是手机通知标志（只发 `PiAlert.entering` 定义的两种转换）：
  /// 一次性事件，只存在于未上传的版本上——置位后，同一状态下的后续写入（如仍在等、只换了问题文本）在上传之前沿用它
  /// （见 `writePiState`）；服务端接受上传即清掉（`CueStore.markPushed`），此后本机的任何改动都不会再带上，订阅不会为同一次
  /// 等待重复通知。状态一旦前进（如用户答完回到思考中），未上传的标志随之作废——已恢复工作的会话不该再提示"等你确认"。
  /// 会话结束（`end`）清掉标志，未上传的也不再通知。
  private func commit(
    _ sessionID: String, _ session: inout Session, _ content: PiStateContent, notify: PiAlert? = nil, at now: Date
  ) -> @Sendable () async throws -> Void {
    session.written = content
    session.writtenAt = now
    return { [store, hostID] in
      try await store.writePiState(sessionID: sessionID, hostID: hostID, content: content, notify: notify)
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
  private func forgetWritten(_ sessionID: String, _ content: PiStateContent) {
    if sessions[sessionID]?.written == content { sessions[sessionID]?.written = nil }
  }

  private func cancelPending(_ session: inout Session) {
    session.timer?.cancel()
    session.timer = nil
  }
}
