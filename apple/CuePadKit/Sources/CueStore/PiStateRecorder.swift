import Foundation

extension CueStore {
  /// `notify` 只置给你的提示（`PiAlert.reaches`）：会话由 Cue 跟进时进入等回答不置，这类提问 Cue 处理，要你拍板的它会发"等你"。
  /// `catalog`：会话报的模型与命令所在的目录记录；`writesCatalog` 为真（这个会话报的变了或还没写过）才写它，
  /// 不必每次状态变化都去比一遍几十 KB 的清单。
  func writePiState(
    sessionID: String, hostID: String, content: PiStateContent, catalog: AgentCatalog?, writesCatalog: Bool, notify: PiAlert?
  ) throws {
    try write {
      let now = Date.stamp
      var record = PiSessionState(
        id: PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, hostID: hostID, title: content.title,
        projectID: content.projectID, state: .known(content.state), detail: content.detail, folder: content.folder, lastPrompt: nil,
        lastReply: nil, question: content.question, notify: notify.map(Open.known), stateSince: content.times.stateSince,
        busySince: content.times.busySince, createdAt: now, modifiedAt: now, launchToken: content.launchToken, hosted: content.hosted,
        subagents: content.subagents, model: content.modelState.model, thinking: content.modelState.thinking,
        context: content.context, agent: .known(content.agent), catalogID: catalog?.id)
      if writesCatalog, let catalog { try writeCatalog(catalog) }
      if let alert = notify, alert == .waitingForUser,
        !alert.reaches(record, cueFollows: try db.first("SELECT 1 WHERE \(Self.followedByCue("?"))", [sessionID], { _ in true }) != nil)
      {
        record.notify = nil
      }
      // 摘要不归这里写：它是对话的投影，只由 `writePiTranscript` 写（新记录插入时先空着）
      let assignments = PiSessionState.columns.dropFirst()
        .filter { $0 != "createdAt" && $0 != "notify" && !PiSessionState.recapColumns.contains($0) }
        .map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
      let placeholders = PiSessionState.columns.map { _ in "?" }.joined(separator: ", ")
      try followTitle(of: sessionID, to: content.title)
      try db.run(
        """
        INSERT INTO piSessionStates (\(PiSessionState.columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments),
          notify = CASE
            WHEN excluded.notify IS NOT NULL THEN excluded.notify
            WHEN piSessionStates.notify IS NOT NULL AND piSessionStates.state = excluded.state THEN piSessionStates.notify
          END
        """, record.bindings)
      if let process = content.process {
        try db.run(
          "INSERT OR REPLACE INTO piProcesses (sessionID, pid, startedAt) VALUES (?, ?, ?)", [sessionID, Int64(process.pid), process.startedAt])
      }
      if content.launchToken != nil { try claimLaunchedCards() }
      try dropUnusedCatalogs(host: hostID)
    }
  }

  /// 一个会话的进程没了（不是你结束的：崩溃、被杀、更新时让旧扩展的托管进程退出）：托管的记为歇着（仍可唤醒、不进历史），
  /// 其余记为已结束、进历史；记录上手上还有活（在跑一轮、等你确认、子代理还在跑）的都记为做到一半被打断（`PiWorkState.interrupted`）。
  func losePiState(host: String, sessionID: String, at now: Date) throws {
    try write {
      try close(where: "id = ?", [PiSessionState.recordID(sessionID: sessionID)], at: now)
      try db.run("DELETE FROM piProcesses WHERE sessionID = ?", [sessionID])
      try dropUnusedCatalogs(host: host)
    }
  }

  /// 你结束了这个会话：记为已结束、进历史（不算被打断）；已结束、被打断的也改记为已结束。
  func endPiState(host: String, sessionID: String, at now: Date) throws {
    try write {
      try db.run(
        "UPDATE piSessionStates SET state = ?, \(Self.cleared), stateSince = ?, hosted = NULL, modifiedAt = ? WHERE id = ? AND state != ?",
        [PiWorkState.ended.rawValue, now, Date.stamp, PiSessionState.recordID(sessionID: sessionID), PiWorkState.ended.rawValue])
      try db.run("DELETE FROM piProcesses WHERE sessionID = ?", [sessionID])
      try dropUnusedCatalogs(host: host)
    }
  }

  /// 启动对账：只收尾这台 Mac 上记下的进程确实没了的记录（`running` 判断记下的进程是不是还是那一个），按进程没了收尾
  /// （`losePiState`），手上还有活的记为被打断。其余一律不动：记下的进程还在的（托管的 Pi 不随 App 退出，终端里的会话也还开着），
  /// 与没记下进程、不知道还在不在的（如刚升级、本机进程表还空着），都由桥重新连上后接着写，或在进程退出时收尾。
  func reconcilePiStates(host: String, running: (PiProcess) -> Bool, at now: Date) throws {
    try write {
      let processes = try db.query(
        "SELECT p.sessionID, p.pid, p.startedAt FROM piProcesses p JOIN piSessionStates s ON s.sessionID = p.sessionID WHERE s.hostID = ?",
        [host]
      ) { (sessionID: $0.text(0), process: PiProcess(pid: Int32($0.int(1)), startedAt: $0.int(2))) }
      let gone = processes.filter { !running($0.process) }.map(\.sessionID)
      guard !gone.isEmpty else { return }
      let among = "(\(gone.map { _ in "?" }.joined(separator: ", ")))"
      try close(where: "hostID = ? AND sessionID IN \(among)", [host] + gone.map { $0 as any SQLBindable }, at: now)
      try db.run("DELETE FROM piProcesses WHERE sessionID IN \(among)", gone.map { $0 as any SQLBindable })
      try dropUnusedCatalogs(host: host)
    }
  }

  /// 进程没了的收尾（见 `losePiState`），只动还没收尾的（不是已结束、被打断）：托管的歇着，其余已结束，手上还有活的记为被打断。
  /// 被打断与已结束的起点是此刻；托管的本来就歇着的不动起点（"多久前"仍从它歇下算起）。
  /// 托管标记照旧：托管的被打断了也由本机在后台唤醒。
  private func close(where condition: String, _ arguments: [any SQLBindable], at now: Date) throws {
    let finals = [PiWorkState.ended, .interrupted].map { "'\($0.rawValue)'" }.joined(separator: ", ")
    let state = """
      CASE WHEN \(Self.hadWork) THEN '\(PiWorkState.interrupted.rawValue)' WHEN hosted = 1 THEN '\(PiWorkState.settled.rawValue)'
        ELSE '\(PiWorkState.ended.rawValue)' END
      """
    try db.run(
      """
      UPDATE piSessionStates SET stateSince = CASE WHEN state = '\(PiWorkState.settled.rawValue)' AND NOT \(Self.hadWork) THEN stateSince ELSE ? END,
        state = \(state), \(Self.cleared), modifiedAt = ?
      WHERE state NOT IN (\(finals)) AND \(condition)
      """, [now, Date.stamp] + arguments)
  }

  /// 进程不在了的记录不留的东西：此刻的说明、问题、通知、计时、子代理、可选模型与命令（目录记录）。
  private static let cleared = "detail = NULL, question = NULL, notify = NULL, busySince = NULL, subagents = NULL, catalogID = NULL"

  /// 记录上手上还有活（在跑一轮、等你确认、子代理还在跑）：进程这时没了就是做到一半被打断。用在 UPDATE 的 SET 里，读的是更新前的行。
  private static let hadWork: String = {
    let pending = PiWorkState.allCases.filter(\.hasPendingWork).map { "'\($0.rawValue)'" }.joined(separator: ", ")
    let running = "EXISTS (SELECT 1 FROM json_each(subagents) WHERE json_extract(value, '$.state') = '\(PiSubagentPhase.running.rawValue)')"
    return "(state IN (\(pending)) OR \(running))"
  }()

  /// 删掉这台 Mac 上歇着的托管会话里没有会话文件索引的记录（文件被删的、从没落盘的）；`live` 是此刻在线的会话，不动。
  func deleteUnindexedHostedStates(host: String, except live: Set<String>) throws {
    let refs = live.isEmpty ? "" : "AND sessionID NOT IN (\(Array(repeating: "?", count: live.count).joined(separator: ", ")))"
    var arguments: [any SQLBindable] = [host, PiWorkState.ended.rawValue]
    arguments += live.sorted().map { $0 as any SQLBindable }
    try write {
      try dropSessionRecords(
        where: "hostID = ? AND hosted = 1 AND state != ? AND sessionID NOT IN (SELECT id FROM piSessions) \(refs)", arguments)
      try dropUnusedCatalogs(host: host)
    }
  }

  /// 删掉一个会话的记录（同步删除）：会话结束时没有留下会话文件的，不进历史。
  func deletePiState(host: String, sessionID: String) throws {
    try write {
      try dropSessionRecords(where: "id = ?", [PiSessionState.recordID(sessionID: sessionID)])
      try db.run("DELETE FROM piProcesses WHERE sessionID = ?", [sessionID])
      try dropUnusedCatalogs(host: host)
    }
  }
}

/// 承载会话的进程（本机）：pid 加启动时刻（微秒）——pid 会被复用，启动时刻对上才是同一个进程。启动对账据此分清进程还在不在
/// （`CueStore.reconcilePiStates`）；只记在本机表 `piProcesses`，不同步。
public struct PiProcess: Equatable, Sendable {
  public var pid: Int32
  public var startedAt: Int64

  public init(pid: Int32, startedAt: Int64) {
    self.pid = pid
    self.startedAt = startedAt
  }
}

/// 会话记录上由 Pi 桥与记录器写的全部字段（摘要不在其中）：会话的当前值、已写入的值与落盘用的是同一个形状。
struct PiStateContent: Equatable, Sendable {
  var state: PiWorkState
  var detail: String?
  var title = ""
  /// 工作目录（完整路径，不同步）：记录上只写文件夹名。
  var directory: String?
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
  /// 承载它的进程（只写本机表，不进同步记录）；不知道为 nil。
  var process: PiProcess?

  var folder: String? { directory.flatMap(CueStore.folderName(ofWorkingDirectory:)) }

  /// 这个会话的目录记录；什么都没报的没有。
  func catalog(host: String, at now: Date) -> AgentCatalog? {
    guard !modelState.models.isEmpty || !commands.isEmpty else { return nil }
    return AgentCatalog(host: host, models: modelState.models, commands: commands, at: now)
  }

  /// 模型与命令和上次写的（`written`，没写过为 nil）不同。
  func catalogDiffers(from written: PiStateContent?) -> Bool {
    written.map { $0.modelState.models != modelState.models || $0.commands != commands } ?? true
  }

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
/// - 工作中的细节变化（输出、调用哪个工具）：合并，两次写入之间至少隔 `minInterval`（默认 `detailInterval`），期间只保留最新的一次；
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
    /// `written` 的目录记录（模型与命令没变时沿用，不重算内容的 id）
    var catalog: AgentCatalog?
    /// 有挂起的更新（节流期内只保留最新一次，就是 `content`）时在等的定时写入
    var timer: Task<Void, Never>?
  }

  /// 工作中细节的最短写入间隔：每次写入都是一次整条记录的上传与各端的下载。
  /// 另有调研在评估它与流式显示（看着 Agent 一句句写出来）是否冲突，可能再调。
  public static let detailInterval: Duration = .seconds(15)

  private let store: CueStore
  private let hostID: String
  private let minInterval: Duration
  private let timing: Timing
  private var sessions: [String: Session] = [:]
  private var tail: Task<Void, Never>?

  public init(store: CueStore, hostID: String, minInterval: Duration = detailInterval, timing: Timing = .system) {
    self.store = store
    self.hostID = hostID
    self.minInterval = minInterval
    self.timing = timing
  }

  /// 没给的字段（nil）沿用上一次的值；`question` 与 `detail` 每次整体替换。
  /// 返回这次写入置位的通知标志（没有置位为 nil）：调用方据此立即上传这一条，通知不等引擎的自动调度。
  @discardableResult
  public func update(
    sessionID: String, state: PiWorkState, detail: String? = nil, title: String? = nil, directory: String? = nil,
    projectID: UUID? = nil, question: PiQuestion? = nil, times: PiTimes? = nil, launchToken: String? = nil, hosted: Bool? = nil,
    subagents: [PiSubagentState]? = nil, modelState: PiModelState? = nil, context: PiContextUsage? = nil, commands: [PiSlashCommand]? = nil,
    agent: AgentKind? = nil, process: PiProcess? = nil
  ) async throws -> PiAlert? {
    var session = sessions[sessionID] ?? Session()
    // 托管着的旧扩展会话（App 更新后）：读不到它在做什么，PiHost 马上让它退出，下次发话用新扩展恢复。
    // 不写：记录留着上一次读到的样子，退出时据此分清是不是做到一半被打断（`exited`）
    if state == .incompatible, hosted ?? session.content?.hosted ?? false { return nil }
    let now = timing.now()
    let previous = session.content.map { (state: $0.state, since: $0.times.stateSince) }
    // 调用方给的计时基准；没给过时（测试、演示）用第一次写入的时间，之后不变
    var content = session.content ?? PiStateContent(state: state, times: PiTimes(stateSince: now, busySince: nil))
    content.state = state
    content.detail = detail
    content.question = question
    if let title { content.title = title }
    if let directory { content.directory = directory }
    if let projectID { content.projectID = projectID }
    if let times { content.times = times }
    if let launchToken { content.launchToken = launchToken }
    if let hosted { content.hosted = hosted }
    if let subagents { content.subagents = subagents }
    if let modelState { content.modelState = modelState }
    if let context { content.context = context }
    if let commands { content.commands = commands }
    if let agent { content.agent = agent }
    if let process { content.process = process }
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

  /// 用户结束会话：记录标为已结束，进历史（不算被打断）。
  public func end(sessionID: String) async throws {
    if var session = sessions.removeValue(forKey: sessionID) { cancelPending(&session) }
    let now = timing.now()
    try await persist { [store, hostID] in try await store.endPiState(host: hostID, sessionID: sessionID, at: now) }
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
  /// 后两种在记录上手上还有活时记为做到一半被打断（`PiWorkState.interrupted`：崩溃、被杀、App 更新时让旧扩展的托管进程退出）。
  /// 托管的会话要结束，由用户的结束请求写 `end`。
  public func exited(sessionID: String, spoke: Bool) async throws {
    if var session = sessions.removeValue(forKey: sessionID) { cancelPending(&session) }
    let id = sessionID
    let now = timing.now()
    if spoke {
      try await persist { [store, hostID] in try await store.losePiState(host: hostID, sessionID: id, at: now) }
    } else {
      try await persist { [store, hostID] in try await store.deletePiState(host: hostID, sessionID: id) }
    }
  }

  /// App 启动时对账这台 Mac 上次留下的记录：记下的进程确实没了的按 `exited` 收尾（手上还有活的记为被打断），其余不动——
  /// 进程还在的（托管的 Pi 不随 App 退出，终端里的会话也还开着）与没记下进程的，由桥重新连上后接着写。`running` 判断记下的进程是不是还是那一个。
  public func reset(running: @escaping @Sendable (PiProcess) -> Bool) async throws {
    for id in Array(sessions.keys) {
      if var session = sessions.removeValue(forKey: id) { cancelPending(&session) }
    }
    let now = timing.now()
    try await persist { [store, hostID] in try await store.reconcilePiStates(host: hostID, running: running, at: now) }
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
    let writesCatalog = content.catalogDiffers(from: session.written)
    if writesCatalog { session.catalog = content.catalog(host: hostID, at: now) }
    session.written = content
    session.writtenAt = now
    return { [store, hostID, catalog = session.catalog] in
      try await store.writePiState(
        sessionID: sessionID, hostID: hostID, content: content, catalog: catalog, writesCatalog: writesCatalog, notify: notify)
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
