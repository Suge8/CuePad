import Foundation

extension CueStore {
  /// 会话列表的一页（Mac 与手机共用的唯一查询）。顺序见 `PiSessionPage`。
  public func piSessionPage(_ query: PiSessionQuery) throws -> PiSessionPage {
    var conditions: [String] = []
    var arguments: [any SQLBindable] = []
    switch query.scope {
    case .live: conditions.append(PiWorkState.outsideSQL([.ended]))
    case .ended: conditions.append("state = '\(PiWorkState.ended.rawValue)'")
    case .all: break
    case .current:
      conditions.append(
        """
        (\(PiWorkState.outsideSQL([.ended])) OR sessionID IN (SELECT targetRef FROM deliveryRequests
          WHERE targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode IN (\(sqlList(DeliveryMode.toSession)))))
        """)
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
      PiSessionState.self, where: condition, arguments, orderBy: "state = '\(PiWorkState.ended.rawValue)', stateSince DESC, id",
      limit: query.limit, offset: query.offset)
    let total = try db.first("SELECT count(*) FROM piSessionStates WHERE \(condition)", arguments) { Int($0.int(0)) } ?? 0
    return PiSessionPage(items: try listItems(states), total: total)
  }

  /// 一批会话（Pi 的会话 id）的列表项，按会话 id 索引；没有记录的 id 不在结果里。行与卡上要显示几十个会话的状态时一次读出，
  /// 不必一个会话查一次。
  public func piSessions(sessionIDs: [String]) throws -> [String: PiSessionListItem] {
    guard !sessionIDs.isEmpty else { return [:] }
    let ids = String(decoding: try JSONEncoder().encode(sessionIDs), as: UTF8.self)
    let states = try select(PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [ids])
    return Dictionary(try listItems(states).map { ($0.state.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// 全部会话记录数（在线的与历史）。
  public func piSessionCount() throws -> Int {
    try db.first("SELECT count(*) FROM piSessionStates") { Int($0.int(0)) } ?? 0
  }

  /// 会话记录配上列表项要的其余几样（项目、最近一条投送请求、改名、没送达的话）：分页与按 id 取的唯一组装处。
  private func listItems(_ states: [PiSessionState]) throws -> [PiSessionListItem] {
    let ids = states.map(\.sessionID)
    let projects = Dictionary(uniqueKeysWithValues: try self.projects().map { ($0.id, $0) })
    let deliveries = try latestDeliveries(to: ids)
    let renames = try latestRenames(to: ids)
    let unsettled = try unsettledTalk(to: ids)
    return states.map {
      PiSessionListItem(
        state: $0, project: $0.projectID.flatMap { projects[$0] }, delivery: deliveries[$0.sessionID], rename: renames[$0.sessionID],
        unsettled: unsettled[$0.sessionID] ?? [])
    }
  }

  /// 在问你的会话："等你"里会话那一半（规则在 `PiSessionState.asksYou`，汇总在 `cueTally`）。只读在等回答的与 Cue 留给你回的那几条，订阅也只依赖它们（`narrow`）：
  /// 别的会话变状态时"等你"不重读。
  public func sessionsAskingYou() throws -> [PiSessionState] {
    let cue = try cueDuty()
    let waiting = PiWorkState.waitingForUser.rawValue, settled = PiWorkState.settled.rawValue
    let left = JSONColumn.encode(cue?.left.map(\.sessionID) ?? []).replacingOccurrences(of: "'", with: "''")
    let candidates = "state = '\(waiting)' OR (state = '\(settled)' AND sessionID IN (SELECT value FROM json_each('\(left)')))"
    return try narrow(.piSessionStates, column: "state", candidates: candidates, to: { $0 == waiting || $0 == settled }) { rows in
      rows.isEmpty ? [] : try select(PiSessionState.self, where: "rowid IN (SELECT value FROM json_each(?))", [JSONColumn.encode(rows.sorted())])
        .filter { $0.asksYou(cue) }
    }
  }

  /// 发给这些会话的最近一条改名，按 Pi 的会话 id（取法见 `DeliveryRequest.latestRename`）。
  func latestRenames(to sessionIDs: [String]) throws -> [String: DeliveryRequest] {
    guard !sessionIDs.isEmpty else { return [:] }
    let refs = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
    let configs = try select(
      DeliveryRequest.self,
      where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode = '\(DeliveryMode.config.rawValue)' AND targetRef IN (\(refs))",
      sessionIDs, orderBy: "createdAt, rowid")
    return Dictionary(grouping: configs) { $0.target.ref ?? "" }.compactMapValues(DeliveryRequest.latestRename(in:))
  }

  /// 发给这些会话、可能没能送达的话，按 Pi 的会话 id：说的话（`DeliveryMode.send`）里还没被领取的与失败的——
  /// 哪几句此刻算没能送达由说的话那条规则定（`PiSessionListItem.undelivered`）。失败的话不会进对话，一直留到你重发
  /// （新请求写成后删掉旧的）或移除；作答、命令、设置不是说的话，不算。
  func unsettledTalk(to sessionIDs: [String]) throws -> [String: [DeliveryRequest]] {
    guard !sessionIDs.isEmpty else { return [:] }
    let refs = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
    let requests = try select(
      DeliveryRequest.self,
      where: """
        targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode = '\(DeliveryMode.send.rawValue)'
          AND status IN ('\(DeliveryStatus.pending.rawValue)', '\(DeliveryStatus.failed.rawValue)') AND targetRef IN (\(refs))
        """, sessionIDs, orderBy: "createdAt, rowid")
    return Dictionary(grouping: requests) { $0.target.ref ?? "" }
  }

  /// 发给这些会话的最近一条投送请求（只算 `DeliveryMode.toSession` 的方式），按 Pi 的会话 id。
  /// 一次查询按会话聚合；投送请求完成后不久就被执行它的 Mac 清理，表一直很小。
  func latestDeliveries(to sessionIDs: [String]) throws -> [String: DeliveryRequest] {
    guard !sessionIDs.isEmpty else { return [:] }
    let refs = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
    let requests = try select(
      DeliveryRequest.self,
      where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode IN (\(sqlList(DeliveryMode.toSession))) AND targetRef IN (\(refs))",
      sessionIDs, orderBy: "createdAt DESC, rowid DESC")
    var latest: [String: DeliveryRequest] = [:]
    for request in requests {
      if let ref = request.target.ref, latest[ref] == nil { latest[ref] = request }
    }
    return latest
  }

  /// `host` 那台 Mac 上 `since` 之后结束的会话，最近结束的在前，至多 `limit` 个：Mac 的发送目标据此认出"刚结束的会话"，
  /// 历史会话（结束时间早于 `since`）不在其中。
  public func endedSessions(on host: String, since: Date, limit: Int) throws -> [PiSessionState] {
    try select(
      PiSessionState.self, where: "state = ? AND hostID = ? AND stateSince >= ?", [PiWorkState.ended.rawValue, host, since],
      orderBy: "stateSince DESC, id", limit: limit)
  }

  /// 一个会话记录里最后的模型（在 CuePad 里看到、选的那个；会话结束后仍留着）。
  public func lastModel(ofSession sessionID: String) throws -> PiModelKey? {
    try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))?.model?.key
  }

  /// 各台 Mac 上跑过 Agent 的文件夹（会话记录的文件夹名，同一台 Mac 同名的算一个）：会话数、最近的那个会话与它归的项目；最近有会话的在前，同样近的会话多的在前。临时目录的会话没有文件夹名（`folderName(ofWorkingDirectory:)`），不在其中。
  /// 手机据此建议给项目绑哪个文件夹（见 `PiBind`）；几千条历史聚合成几十行，不整表读。
  public func sessionFolders() throws -> [SessionFolder] { try folders(where: Self.hasFolder, []) }

  /// 同上，只要名字（小写）在 `names` 里的文件夹（不分大小写，同 `ProjectFolders.suggestions`）。订阅只依赖这些文件夹里的会话（`narrow`）：
  /// 别的会话状态变化不叫醒它——项目引导曾在每次会话状态变化时把全部会话按文件夹重新聚合一遍。
  public func sessionFolders(named names: Set<String>) throws -> [SessionFolder] {
    try narrow(.piSessionStates, column: "folder", candidates: Self.hasFolder, to: { names.contains($0.lowercased()) }) { rows in
      rows.isEmpty ? [] : try folders(where: "rowid IN (SELECT value FROM json_each(?))", [JSONColumn.encode(rows.sorted())])
    }
  }

  /// 记着文件夹的会话：也是文件夹索引（`Schema` 第 55 步）的部分条件，不一样就用不上。
  static let hasFolder = "folder IS NOT NULL AND folder != ''"

  private func folders(where condition: String, _ arguments: [any SQLBindable]) throws -> [SessionFolder] {
    try db.query(
      """
      SELECT hostID, folder, sessionID, projectID, count(*), max(stateSince), \(MacAgents.nameSQL(host: "piSessionStates.hostID"))
      FROM piSessionStates WHERE \(condition) GROUP BY hostID, folder ORDER BY max(stateSince) DESC, count(*) DESC, hostID, folder
      """, arguments
    ) {
      SessionFolder(
        hostID: $0.text(0), folder: $0.text(1), sessionID: $0.text(2), projectID: $0.uuidOrNil(3), count: Int($0.int(4)),
        macName: MacAgents.shownName($0.textOrNil(6)))
    }
  }
}
