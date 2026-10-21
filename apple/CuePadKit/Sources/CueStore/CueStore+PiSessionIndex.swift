import CueText
import Foundation

extension CueStore {
  /// 插入或更新会话索引（本机，不同步）；`checkpoint` 为 nil 时保留已存的检查点，非 nil 时在同一事务里替换。
  /// 同一事务里把它写成这个会话的同步记录（见 `writePiHistory`），`host` 是这台 Mac。
  /// `transcript` 是同一次读会话文件得到的对话与摘要，在同一事务里写（见 `writePiTranscript`）。
  public func upsertPiSession(_ session: IndexedSession, checkpoint: Data? = nil, host: String, transcript: PiTranscript? = nil) throws {
    try upsertPiSessions([PiSessionUpsert(session: session, checkpoint: checkpoint, transcript: transcript)], host: host)
  }

  /// 一批会话索引在同一个事务里写（首次回填几千个文件时：一次提交、一次变更通知，界面不为每个文件重读重画）。
  public func upsertPiSessions(_ batch: [PiSessionUpsert], host: String) throws {
    let assignments = IndexedSession.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    let placeholders = (IndexedSession.columns + ["checkpoint"]).map { _ in "?" }.joined(separator: ", ")
    try write {
      let bound = try boundDirectories()
      for item in batch {
        try writePiHistory(item.session, host: host, bound: bound)
        if let transcript = item.transcript { try applyTranscript(transcript) }
        try db.run(
          """
          INSERT INTO piSessions (\(IndexedSession.columns.joined(separator: ", ")), checkpoint) VALUES (\(placeholders))
          ON CONFLICT(id) DO UPDATE SET \(assignments),
            checkpoint = COALESCE(excluded.checkpoint, piSessions.checkpoint)
          """, item.session.bindings + [item.checkpoint])
      }
    }
  }

  /// 只留下这些会话文件的索引，其余（文件已删除、不再算会话的）删除，返回删掉的条数。
  /// 同时让已结束（与终端里被打断）的记录与会话文件一一对应：删掉这台 Mac 上没有会话文件的这类记录（文件被删的；从没落盘的，
  /// 如 `--no-session` 或没发过消息的），补写有会话文件却没有记录的。在线的不动；
  /// 歇着的托管会话同样要有会话文件，由 `PiStateRecorder.dropUnindexedHosted` 对账（它知道哪些是此刻在线的）。
  /// 每个 Agent 的索引各自对账自己的会话（`agent`），别家的不动。
  @discardableResult
  public func retainPiSessions(paths: Set<String>, agent: AgentKind, host: String) throws -> Int {
    try write {
      let indexed = try db.query("SELECT id, path FROM piSessions WHERE \(Self.agentOf) = ?", [agent.rawValue]) { ($0.text(0), $0.text(1)) }
      let stale = indexed.filter { !paths.contains($0.1) }
      for (id, _) in stale { try db.run("DELETE FROM piSessions WHERE id = ?", [id]) }
      try db.run(
        """
          DELETE FROM piSessionStates WHERE hostID = ? AND (state = ? OR state = ? AND hosted IS NULL) AND \(Self.agentOf) = ? AND sessionID NOT IN (SELECT id FROM piSessions)
          """,
        [host, PiWorkState.ended.rawValue, PiWorkState.interrupted.rawValue, agent.rawValue])
      // 反过来，有会话文件却没有记录的补写：换 iCloud 账号丢掉同步数据（`eraseSyncedData`，本机索引留着）、记录在别处被删之后
      let unrecorded = try select(
        IndexedSession.self, where: "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.sessionID = piSessions.id)")
      let bound = try boundDirectories()
      for session in unrecorded { try writePiHistory(session, host: host, bound: bound) }
      return stale.count
    }
  }

  /// 一行是哪家 Agent 的（会话索引与会话记录都是）：早于多家接入的行没写，是 Pi。也是 Agent 索引（`Schema.agentIndex`）的表达式。
  static let agentOf = "COALESCE(agent, '\(AgentKind.pi.rawValue)')"

  /// 删掉一家 Agent 的本机会话索引（断开接入时）：会话同步记录与对话不动。`host` 这台 Mac 托管过的会话（`hostedPiSessionIDs`）留着：
  /// 没接入也照样开、照样读对话，闲置退出或结束后再发话要靠索引接着它（`MacExecutor`）。
  public func deletePiSessions(of agent: AgentKind, keepingHostedOn host: String) throws {
    try write {
      try db.run(
        "DELETE FROM piSessions WHERE \(Self.agentOf) = ? AND id NOT IN (\(Self.hostedSessionsSQL))", [agent.rawValue, host, agent.rawValue])
    }
  }

  /// `host` 这台 Mac 托管过的这家的会话：CuePad 开的（带认领标识，结束了也留着），与此刻托管着的（接着已结束的会话时不带标识）。
  /// 没接入的 Agent 只索引这些（`PiHistoryScope.sessions`）。
  public func hostedPiSessionIDs(of agent: AgentKind, host: String) throws -> Set<String> {
    Set(try db.query(Self.hostedSessionsSQL, [host, agent.rawValue]) { $0.text(0) })
  }

  private static let hostedSessionsSQL = "SELECT sessionID FROM piSessionStates WHERE hostID = ? AND \(agentOf) = ? AND \(hostedOrLaunched)"

  /// 托管着的或 CuePad 开的会话记录（唯一定义，也是它的部分索引的条件）。
  static let hostedOrLaunched = "(hosted = 1 OR launchToken IS NOT NULL)"

  /// 本机索引里的一个会话（会话文件路径与工作目录）。
  public func piSession(_ id: String) throws -> IndexedSession? { try find(IndexedSession.self, id) }

  /// 会话文件索引写成同步记录：没有记录时插入一条已结束的；已结束的记录更新名字、所在与最后活动时间（没变不写，
  /// 免得检查点作废、从头重读时把几千条历史重新上传）；在线的不动（由状态写入方负责）。必须在写事务内调用。
  /// 变没变在 SQL 里按库里存的精度比：读会话文件得到的时间带亚毫秒，库里是毫秒，在 Swift 里比几乎总是"变了"。
  private func writePiHistory(_ session: IndexedSession, host: String, bound: [BoundDirectory]) throws {
    let id = PiSessionState.recordID(sessionID: session.id)
    let cwd = URL(filePath: session.cwd, directoryHint: .isDirectory)
    let folder = Self.folderName(ofWorkingDirectory: session.cwd)
    let title = session.title.isEmpty ? (session.cwd.isEmpty ? "" : cwd.lastPathComponent) : session.title
    let projectID = session.cwd.isEmpty ? nil : Self.projectID(containing: cwd, in: bound)
    let now = Date.stamp
    guard let existing = try find(PiSessionState.self, id) else {
      _ = try insert(PiSessionState(
        id: id, sessionID: session.id, hostID: host, title: title, projectID: projectID, state: .known(.ended), detail: nil,
        folder: folder, lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: session.lastActivityAt,
        busySince: nil, createdAt: now, modifiedAt: now, agent: .known(session.agent)))
      return
    }
    guard existing.state == .known(.ended) else { return }
    try db.run(
      """
      UPDATE piSessionStates SET title = ?1, folder = ?2, projectID = ?3, stateSince = MAX(stateSince, ?4), modifiedAt = ?5
      WHERE id = ?6 AND (title IS NOT ?1 OR folder IS NOT ?2 OR projectID IS NOT ?3 OR stateSince < ?4)
      """, [title, folder, projectID, session.lastActivityAt, now, id])
  }
}

extension CueStore {
  /// 会话的检查点（服务层存入的不透明字节）；会话不存在或尚未索引返回 nil。
  public func piCheckpoint(of session: String) throws -> Data? {
    try db.first("SELECT checkpoint FROM piSessions WHERE id = ?", [session]) { $0.blobOrNil(0) } ?? nil
  }

  /// 全部会话索引各从哪接着读（按会话文件路径）：检查点，与本机有没有它的对话。历史索引启动时一次读出，不逐个文件查。
  public func piIndexStarts() throws -> [String: IndexedSessionStart] {
    let rows = try db.query(
      "SELECT path, id, checkpoint, EXISTS (SELECT 1 FROM piMessages m WHERE m.sessionID = s.id) FROM piSessions s"
    ) { ($0.text(0), IndexedSessionStart(id: $0.text(1), checkpoint: $0.blobOrNil(2), hasMessages: $0.int(3) != 0)) }
    return Dictionary(rows, uniquingKeysWith: { first, _ in first })
  }

  public func piSessions() throws -> [IndexedSession] {
    try select(IndexedSession.self, orderBy: "lastActivityAt DESC, id")
  }
}
