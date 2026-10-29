import Foundation

extension CueStore {
  /// `notify` 是这次写入进入的那种提示（`PiAlert.entering`），怎么推到手机只按 `CueStore.push`。
  /// `catalog`：会话报的模型与命令所在的目录记录；`writesCatalog` 为真（这个会话报的变了或还没写过）才写它，
  /// 不必每次状态变化都去比一遍几十 KB 的清单。
  func writePiState(
    sessionID: String, hostID: String, bootID: String?, content: PiStateContent, catalog: AgentCatalog?, writesCatalog: Bool, notify: PiAlert?
  ) throws {
    try write {
      let now = Date.stamp
      var record = PiSessionState(
        id: PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, hostID: hostID, title: content.title,
        projectID: content.projectID, state: .known(content.state), detail: content.detail, folder: content.folder, lastPrompt: nil,
        lastReply: nil, question: content.question, notify: nil, stateSince: content.times.stateSince,
        busySince: content.times.busySince, createdAt: now, modifiedAt: now, launchToken: content.launchToken, hosted: content.hosted,
        subagents: content.subagents, model: content.modelState.model, thinking: content.modelState.thinking,
        context: content.context, agent: .known(content.agent), catalogID: catalog?.id, turnStartedAt: content.turnStartedAt,
        failure: content.state == .error ? content.failure.map(Open.known) : nil, bootID: bootID)
      if writesCatalog, let catalog { try writeCatalog(catalog) }
      if let notify { record.notify = try push(notify, runtimeProjection([record])[0]) }
      // 摘要不归这里写：它是对话的投影，只由 `writePiTranscript` 写（新记录插入时先空着）
      // 最后一轮的开始不知道（CuePad 在一轮中途重启，各家的事实从头记起）时留着库里的：这一轮的回答照样不早于它
      let assignments = PiSessionState.columns.dropFirst()
        .filter { $0 != "createdAt" && $0 != "notify" && !PiSessionState.recapColumns.contains($0) }
        .map { $0 == "turnStartedAt" ? "turnStartedAt = COALESCE(excluded.turnStartedAt, piSessionStates.turnStartedAt)" : "\($0) = excluded.\($0)" }
        .joined(separator: ", ")
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
      if let process = content.process {
        try db.run(
          "INSERT OR REPLACE INTO piProcesses (sessionID, pid, startedAt) VALUES (?, ?, ?)", [sessionID, Int64(process.pid), process.startedAt])
      }
      if content.launchToken != nil { try claimLaunchedCards() }
      try dropUnusedCatalogs(host: hostID)
    }
  }

  /// 一个会话的进程没了（不是你结束的：崩溃、被杀）：托管的记为歇着（仍可唤醒、不进历史），
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
  /// 返回对账之前还没收尾的各会话的状态与计时（会话 id → ），重新接上时沿用（`PiStateRecorder.update`）。
  func reconcilePiStates(host: String, bootID: String?, running: (PiProcess) -> Bool, at now: Date) throws -> [String: (state: PiWorkState, times: PiTimes)] {
    try write {
      let before = try db.query(
        // `+hostID`：不走 hostID 索引（这台 Mac 的会话几乎就是全部），改走 state 索引只读没收尾的那几条
        "SELECT sessionID, state, stateSince, busySince FROM piSessionStates WHERE +hostID = ? AND \(PiWorkState.outsideSQL(PiWorkState.closed))", [host]
      ) { row in (row.text(0), PiWorkState(rawValue: row.text(1)), PiTimes(stateSince: row.date(2), busySince: row.dateOrNil(3))) }
      let open = Dictionary(before.compactMap { id, state, times in state.map { (id, ($0, times)) } }) { $1 }
      let processes = try db.query(
        "SELECT p.sessionID, p.pid, p.startedAt FROM piProcesses p JOIN piSessionStates s ON s.sessionID = p.sessionID WHERE s.hostID = ?",
        [host]
      ) { (sessionID: $0.text(0), process: PiProcess(pid: Int32($0.int(1)), startedAt: $0.int(2))) }
      let checked = processes.map { (sessionID: $0.sessionID, alive: running($0.process)) }
      let alive = checked.filter(\.alive).map(\.sessionID)
      if !alive.isEmpty {
        try db.run("UPDATE piSessionStates SET bootID = ?, modifiedAt = ? WHERE hostID = ? AND sessionID IN (SELECT value FROM json_each(?))",
                   [bootID, Date.stamp, host, JSONColumn.encode(alive)])
      }
      let gone = checked.filter { !$0.alive }.map(\.sessionID)
      guard !gone.isEmpty else { return open }
      let among = "(SELECT value FROM json_each(?))", goneList = JSONColumn.encode(gone)
      try close(where: "hostID = ? AND sessionID IN \(among)", [host, goneList], at: now)
      try db.run("DELETE FROM piProcesses WHERE sessionID IN \(among)", [goneList])
      try dropUnusedCatalogs(host: host)
      return open
    }
  }

  /// 进程没了的收尾（见 `losePiState`），只动还没收尾的（不是已结束、被打断）：托管的歇着，其余已结束，手上还有活的记为被打断。
  /// 托管的上一轮出错的仍是出错、原因留着（进程退出不改变那一轮的结果）。
  /// 被打断与已结束的起点是此刻；托管的本来就歇着或出错的不动起点（"多久前"仍从那时算起）。
  /// 托管标记照旧：托管的被打断了也由本机在后台唤醒。
  private func close(where condition: String, _ arguments: [any SQLBindable], at now: Date) throws {
    let failed = "(hosted = 1 AND state = '\(PiWorkState.error.rawValue)')"
    let state = """
      CASE WHEN \(Self.hadWork) THEN '\(PiWorkState.interrupted.rawValue)' WHEN \(failed) THEN state
        WHEN hosted = 1 THEN '\(PiWorkState.settled.rawValue)' ELSE '\(PiWorkState.ended.rawValue)' END
      """
    let kept = "((state = '\(PiWorkState.settled.rawValue)' AND NOT \(Self.hadWork)) OR \(failed))"
    try db.run(
      """
      UPDATE piSessionStates SET stateSince = CASE WHEN \(kept) THEN stateSince ELSE ? END,
        state = \(state), \(Self.cleared), detail = CASE WHEN \(failed) THEN detail END, modifiedAt = ?
      WHERE \(PiWorkState.outsideSQL(PiWorkState.closed)) AND \(condition)
      """, [now, Date.stamp] + arguments)
  }

  /// 进程不在了的记录不留的东西：此刻的说明、问题、通知、计时、子代理。它报过的模型与命令（目录记录）留着：发话、换模型会在后台唤醒它，
  /// 回复框照这份列模型、认命令（`PiSlash.line`）。
  private static let cleared = "bootID = NULL, detail = NULL, question = NULL, notify = NULL, busySince = NULL, subagents = NULL, failure = NULL"

  /// 记录上手上还有活（在跑一轮、等你确认、子代理还在跑）：进程这时没了就是做到一半被打断。用在 UPDATE 的 SET 里，读的是更新前的行。
  private static let hadWork = """
    (state IN (\(PiWorkState.pendingWorkSQL))
      OR EXISTS (SELECT 1 FROM json_each(subagents) WHERE json_extract(value, '$.state') = '\(PiSubagentPhase.running.rawValue)'))
    """

  /// 删掉这台 Mac 上这家 Agent 歇着的托管会话里没有会话文件索引的记录（文件被删的、从没落盘的）；`live` 是此刻在线的会话，不动。
  func deleteUnindexedHostedStates(host: String, agent: AgentKind, except live: Set<String>) throws {
    let arguments: [any SQLBindable] = [host, agent.rawValue, JSONColumn.encode(live.sorted())]
    try write {
      // `+hostID`：同 `reconcilePiStates`，改走 state 索引只读没结束的那几条
      try db.run(
        """
        DELETE FROM piSessionStates WHERE +hostID = ? AND \(Self.agentOf) = ? AND hosted = 1 AND \(PiWorkState.outsideSQL([.ended]))
          AND sessionID NOT IN (SELECT id FROM piSessions) AND sessionID NOT IN (SELECT value FROM json_each(?))
        """,
        arguments)
      try dropUnusedCatalogs(host: host)
    }
  }

  /// 删掉一个会话的记录（同步删除）：会话结束时没有留下会话文件的，不进历史。
  func deletePiState(host: String, sessionID: String) throws {
    try write {
      try db.run("DELETE FROM piSessionStates WHERE id = ?", [PiSessionState.recordID(sessionID: sessionID)])
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
struct PiStateContent: Paced {
  var state: PiWorkState
  var detail: String?
  var title = ""
  /// 工作目录（完整路径，不同步）：记录上只写文件夹名。
  var directory: String?
  var projectID: UUID?
  var question: PiQuestion?
  /// 出错的种类（`PiSessionState.failure`，桥按原文归类）
  var failure: PiFailure?
  var times: PiTimes
  /// 最后一轮开始的时刻（`PiSessionState.turnStartedAt`）
  var turnStartedAt: Date?
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
  var isWorking: Bool { state.isWorking }

  /// 这个会话的目录记录；什么都没报的没有。
  func catalog(host: String, at now: Date) -> AgentCatalog? {
    guard !modelState.models.isEmpty || !commands.isEmpty else { return nil }
    return AgentCatalog(host: host, models: modelState.models, commands: commands, at: now)
  }

  /// 模型与命令和上次写的（`written`，没写过为 nil）不同。
  func catalogDiffers(from written: PiStateContent?) -> Bool {
    written.map { $0.modelState.models != modelState.models || $0.commands != commands } ?? true
  }

  /// 去掉随每次工具调用不断变的细节（状态、说明、子代理的动作、上下文用量、一轮的开始、认领标识）的样子：它变了才值得绕开写入节流（`Pace`）。
  /// 一轮的开始在工作中变了不急着写：歇下立即写，带着的就是最后一轮的。
  var steady: PiStateContent {
    var steady = self
    steady.state = .settled
    steady.detail = nil
    steady.launchToken = nil
    steady.context = nil
    steady.turnStartedAt = nil
    steady.subagents = subagents.map(\.shape)
    return steady
  }
}
