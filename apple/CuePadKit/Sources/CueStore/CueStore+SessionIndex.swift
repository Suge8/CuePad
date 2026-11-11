import CueText
import Foundation

extension CueStore {
  /// 插入或更新会话索引（本机，不同步）；`checkpoint` 为 nil 时保留已存的检查点，非 nil 时在同一事务里替换。
  public func upsertPiSession(_ session: IndexedSession, checkpoint: Data? = nil, host: String, transcript: SessionTranscript? = nil) throws {
    try upsertPiSessions([SessionUpsert(session: session, checkpoint: checkpoint, transcript: transcript)], host: host)
  }

  /// 一批会话索引在同一个事务里写（首次回填几千个文件时：一次提交、一次变更通知，界面不为每个文件重读重画）。
  public func upsertPiSessions(_ batch: [SessionUpsert], host: String) throws {
    try write { try upsertPiSessionRows(batch, host: host) }
  }

  /// 读会话文件之前先记下桥给出的会话文件（投送确认要跟着它）：索引里还没有这个会话才插一行，已有的不动。
  /// 查有没有与插入在同一个事务里：分两步时，中间读会话文件的那一路可能已写下标题与检查点，再插就拿桥上的名字（没报名字时是文件夹名）盖掉标题。
  public func seedPiSession(_ session: IndexedSession, host: String) throws {
    try write {
      guard try find(IndexedSession.self, session.id) == nil else { return }
      try upsertPiSessionRows([SessionUpsert(session: session, checkpoint: nil, transcript: nil)], host: host)
    }
  }

  private func upsertPiSessionRows(_ batch: [SessionUpsert], host: String) throws {
    let assignments = IndexedSession.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    let placeholders = (IndexedSession.columns + ["checkpoint"]).map { _ in "?" }.joined(separator: ", ")
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

  /// 未收尾投送对应的真实文件位置；确认到期也继续由正常历史订阅跟随，直到正证据或请求被清理。
  public func deliveryHistoryFiles(on host: String) throws -> Set<URL> {
    let unsettled = "r.hostID = ?1 AND r.status NOT IN ('\(DeliveryStatus.succeeded.rawValue)', '\(DeliveryStatus.failed.rawValue)')"
    return Set(try db.query(
      """
      SELECT path FROM piSessions p WHERE p.agent = '\(AgentKind.pi.rawValue)' AND p.id IN (
        SELECT r.targetRef FROM deliveryRequests r WHERE \(unsettled) AND r.mode = 'send'
        UNION
        SELECT s.sessionID FROM deliveryRequests r JOIN piSessionStates s ON s.launchToken = \(Self.launchToken("r"))
        WHERE \(unsettled) AND r.mode = 'start')
      """, [host]) { URL(filePath: $0.text(0)) })
  }

  /// 同时让已结束（与终端里被打断）的记录与会话文件一一对应：删掉这台 Mac 上没有会话文件的这类记录（文件被删的；从没落盘的，如 `--no-session` 或没发过消息的），补写有会话文件却没有记录的。在线的不动；歇着的托管会话同样要有会话文件，由 `StateRecorder.dropUnindexedHosted` 对账（它知道哪些是此刻在线的）。每个 Agent 的索引各自对账自己的会话。
  @discardableResult
  public func retainPiSessions(paths: Set<String>, agent: AgentKind, host: String) throws -> Int {
    try write {
      let indexed = try db.query("SELECT id, path FROM piSessions WHERE agent = ?", [agent.rawValue]) { ($0.text(0), $0.text(1)) }
      let retained = agent == .pi ? Set(try deliveryHistoryFiles(on: host).map(\.path)) : []
      let stale = indexed.filter { !paths.contains($0.1) && !retained.contains($0.1) }
      for (id, _) in stale { try db.run("DELETE FROM piSessions WHERE id = ?", [id]) }
      try db.run(
        """
          DELETE FROM piSessionStates WHERE hostID = ? AND (state = ? OR state = ? AND hosted IS NULL) AND agent = ? AND sessionID NOT IN (SELECT id FROM piSessions)
          """,
        [host, WorkState.ended.rawValue, WorkState.interrupted.rawValue, agent.rawValue])
      // 反过来，有会话文件却没有记录的补写：换 iCloud 账号丢掉同步数据（`eraseSyncedData`，本机索引留着）、记录在别处被删之后
      let unrecorded = try select(
        IndexedSession.self, where: "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.sessionID = piSessions.id)")
      let bound = try boundDirectories()
      for session in unrecorded { try writePiHistory(session, host: host, bound: bound) }
      return stale.count
    }
  }

  /// 删掉一家 Agent 的本机会话索引（断开接入时）：会话同步记录与对话不动。`host` 这台 Mac 托管过的会话（`hostedPiSessionIDs`）留着：
  /// 没接入也照样开、照样读对话，闲置退出或结束后再发话要靠索引接着它（`MacExecutor`）。
  public func deletePiSessions(of agent: AgentKind, keepingHostedOn host: String) throws {
    try write {
      try db.run(
        "DELETE FROM piSessions WHERE agent = ? AND id NOT IN (\(Self.hostedSessionsSQL))", [agent.rawValue, host, agent.rawValue])
    }
  }

  /// `host` 这台 Mac 托管过的这家的会话：CuePad 开的（带认领标识，结束了也留着），与此刻托管着的（接着已结束的会话时不带标识）。
  public func hostedPiSessionIDs(of agent: AgentKind, host: String) throws -> Set<String> {
    Set(try db.query(Self.hostedSessionsSQL, [host, agent.rawValue]) { $0.text(0) })
  }

  private static let hostedSessionsSQL = "SELECT sessionID FROM piSessionStates WHERE hostID = ? AND agent = ? AND \(hostedOrLaunched)"

  static let hostedOrLaunched = "(hosted = 1 OR launchToken IS NOT NULL)"

  public func piSession(_ id: String) throws -> IndexedSession? { try find(IndexedSession.self, id) }

  /// 已结束的记录更新名字、所在与最后活动时间（没变不写，免得检查点作废、从头重读时把几千条历史重新上传）；在线的不动（由状态写入方负责）。必须在写事务内调用。
  /// 变没变在 SQL 里按库里存的精度比：读会话文件得到的时间带亚毫秒，库里是毫秒，在 Swift 里比几乎总是“变了”。
  private func writePiHistory(_ session: IndexedSession, host: String, bound: [BoundDirectory]) throws {
    let id = SessionState.recordID(sessionID: session.id)
    let cwd = URL(filePath: session.cwd, directoryHint: .isDirectory)
    let folder = Self.folderName(ofWorkingDirectory: session.cwd)
    let title = session.title.isEmpty ? (session.cwd.isEmpty ? "" : cwd.lastPathComponent) : session.title
    let projectID = session.cwd.isEmpty ? nil : Self.projectID(containing: cwd, in: bound)
    let now = Date.stamp
    guard let existing = try find(SessionState.self, id) else {
      _ = try insert(SessionState(
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
  public func piCheckpoint(of session: String) throws -> Data? {
    try db.first("SELECT checkpoint FROM piSessions WHERE id = ?", [session]) { $0.blobOrNil(0) } ?? nil
  }

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
