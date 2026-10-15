import CueText
import Foundation

/// 活着的会话都属于一个任务叶子：任务树是它的归处，看板、Cue 与项目页都从任务看到会话。
/// 从任务开的会话由认领绑上（`claimLaunchedCards`）；不经任务开的（终端里、"新会话"、别家 Agent），
/// 由写它记录的那台 Mac 在同一个写事务里建一个同名任务挂上（进行中，名字超长截断，`CueName.clipped`）：
/// 归到会话所在文件夹的项目（没有就未分类），排在项目顶层最后。已结束的（历史，含只在会话文件里找到的）不补：留在 Agent 页的历史里。
/// 叶子换会话（开新会话、改绑、Cue 换新会话）时，换下来的会话留在这个叶子下，作为它以前用过的（`Card.formerSessionIDs`，
/// 写在换会话的同一条语句里，`keepingFormerSession`），不另长任务。没结束的会话只有在你亲手解绑、改回灵感、永久删除后没了归处，才补建。
/// 正在用它、用过它的任务都是它的归处，在回收站、已归档的也算。
///
/// 自动建的任务（外壳）id 由会话算出（`sessionTaskID`），它只是会话的投影，自己不另存状态：标题跟着会话改名；会话正常结束，
/// 它跟着完成并归档；被打断、出错的照旧留着（原因看会话状态）；跟着归档后会话又活过来（恢复），它回到进行中。会话没说过话就退出、
/// 记录删掉时它一起删掉。有人动过它（你或 Cue 改了标题、写了提示词、加了步骤、挪了项目、完成或归档），它就是普通任务，
/// 不再跟着会话走。动没动过只看它是不是还是自动建出来的样子（`followShells`），不另记标记。
/// 只有会话记录的那台 Mac 建，手机与命令行不建：同一个游离会话不会在两台设备上各建一个。
extension CueStore {
  /// 这个连接是 Mac `host`：它写的没结束的会话记录从此在每个写事务里都挂在任务上；已有的游离会话当场归位。Mac 启动时调用一次。
  public func ownSessions(host: String) throws {
    sessionHost = host
    try write { try adoptSessions(force: true) }
  }

  /// 会话 → 外壳的对账（每个写事务提交前）：给这台 Mac 记录的、没结束、没有任务绑着的会话建同名任务，外壳跟着会话走
  /// （`followShells`，见类型注释）。写事务改到卡片时查全部会话；只写了会话记录时（状态更新，最频繁的写入）只查写到的那几条。
  func adoptSessions(force: Bool = false) throws {
    guard let host = sessionHost else { return }
    let changes = db.pendingChanges
    var scope: (sql: (String) -> String, rows: [any SQLBindable]) = ({ _ in "" }, [])
    if !force, !changes.tables.contains(Table.cards.rawValue) {
      guard let rows = changes.rows[Table.piSessionStates.rawValue] else { return }
      scope = ({ "AND \($0) IN (SELECT value FROM json_each(?))" }, ["[\(rows.map(String.init).joined(separator: ","))]"])
    }
    try followShells(host: host, within: (scope.sql("s.rowid"), scope.rows))
    let orphans = try select(
      PiSessionState.self,
      where: """
        hostID = ? AND state <> ? \(scope.sql("rowid"))
          AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.piSessionID = piSessionStates.sessionID AND c.todoAt IS NOT NULL)
          AND NOT EXISTS (
            SELECT 1 FROM cards c, json_each(c.formerSessionIDs) f
            WHERE c.formerSessionIDs IS NOT NULL AND c.todoAt IS NOT NULL AND f.value = piSessionStates.sessionID)
        """,
      [host, PiWorkState.ended.rawValue] + scope.rows, orderBy: "createdAt, id")
    guard !orphans.isEmpty else { return }
    let live = Set(try db.query("SELECT id FROM projects WHERE deletedAt IS NULL") { $0.uuid(0) })
    let now = Date.stamp
    let groups = Dictionary(grouping: orphans) { session in session.projectID.flatMap { live.contains($0) ? $0 : nil } }
    for (project, sessions) in groups {
      let last = try db.first("SELECT MAX(sortKey) FROM cards WHERE projectID IS ? AND parentID IS NULL", [project]) { $0.textOrNil(0) } ?? nil
      let base = SortKey.after(last)
      for (session, key) in zip(sessions, SortKey.sequence(count: sessions.count)) {
        let own = Self.sessionTaskID(session.sessionID)
        _ = try insert(Card(
          id: try find(Card.self, own) == nil ? own : UUID(), projectID: project, body: Self.taskTitle(session.title),
          isPinned: false, variableValues: [:], conflictOf: nil, sortKey: base + key, deletedAt: nil, createdAt: now, modifiedAt: now,
          parentID: nil, todoAt: now, startedAt: now, completedAt: nil, piSessionID: session.sessionID, archivedAt: nil))
      }
    }
  }

  /// 外壳跟着会话走，只在这里定（`within` 是对账范围，对会话行 `s`）：没被动过的外壳，会话已结束就完成并归档（完成与归档同一刻），
  /// 没结束（在跑、歇着、被打断、出错）就是进行中——跟着归档过的回到进行中。没被动过 = 还是自动建出来的样子：id 是 `sessionTaskID`、
  /// 标题还是会话名、没有下级、还在会话所在的项目（不在项目里或项目删了是未分类）、不在回收站，开着时没完成也没归档，
  /// 收着时是跟着收尾的样子（完成与归档同一刻）。
  private func followShells(host: String, within scope: (sql: String, rows: [any SQLBindable])) throws {
    let ended = PiWorkState.ended.rawValue
    let stale = try db.query(
      """
      SELECT c.id, c.body, s.sessionID, s.title, s.state = ? FROM piSessionStates s JOIN cards c ON c.piSessionID = s.sessionID
      WHERE s.hostID = ? \(scope.sql) AND c.todoAt IS NOT NULL AND c.parentID IS NULL AND c.deletedAt IS NULL
        AND CASE WHEN s.state = ? THEN c.completedAt IS NULL AND c.archivedAt IS NULL
          ELSE c.completedAt IS NOT NULL AND c.archivedAt = c.completedAt END
        AND c.projectID IS (SELECT id FROM projects WHERE id = s.projectID AND deletedAt IS NULL)
        AND NOT EXISTS (SELECT 1 FROM cards k WHERE k.parentID = c.id)
      """, [ended, host] + scope.rows + [ended]
    ) { (id: $0.uuid(0), body: $0.text(1), session: $0.text(2), title: $0.text(3), ended: $0.int(4) != 0) }
      .filter { $0.id == Self.sessionTaskID($0.session) && $0.body == Self.taskTitle($0.title) }
    let now = Date.stamp
    for (ended, shells) in Dictionary(grouping: stale, by: \.ended) {
      let at: Date? = ended ? now : nil
      try db.run(
        "UPDATE cards SET completedAt = ?1, archivedAt = ?1, modifiedAt = ?2 WHERE id IN (SELECT value FROM json_each(?3))",
        [at, now, Self.idList(shells.map(\.id))])
    }
  }

  /// 叶子换上会话 `new`（SQL 表达式）的 UPDATE 里与 `piSessionID` 一起写的：换下的会话记进 `formerSessionIDs` 末尾，
  /// 换上的（以前用过又换回来的）从里面拿掉，正在用的不在里面。只记任务的：灵感交给别的会话不算用过。
  static func keepingFormerSession(_ new: String) -> String {
    """
    formerSessionIDs = CASE WHEN cards.todoAt IS NULL THEN cards.formerSessionIDs ELSE (
      SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE json_group_array(sid) END FROM (
        SELECT f.value AS sid FROM json_each(COALESCE(cards.formerSessionIDs, '[]')) f WHERE f.value <> \(new)
        UNION ALL
        SELECT cards.piSessionID WHERE cards.piSessionID <> \(new)
          AND NOT EXISTS (SELECT 1 FROM json_each(COALESCE(cards.formerSessionIDs, '[]')) f WHERE f.value = cards.piSessionID)))
    END
    """
  }

  /// 为会话自动建的任务的 id。
  static func sessionTaskID(_ sessionID: String) -> UUID { DeterministicID.uuid("session-task/\(sessionID)") }

  /// 会话名作任务标题：只取第一行有字的（任务正文只有标题），超长截断（终端会话的名字常是第一句话）。
  /// 会话名没有文字时（工作目录也不知道）用 `untitledSession`。
  public static func taskTitle(_ title: String) -> String {
    CueName.clipped(
      title.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? untitledSession)
  }

  static let untitledSession = "Agent 会话"

  /// 会话改名：为它自动建的任务还叫旧名字时跟着改。必须在写事务内、记录写入新名字之前调用。
  func followTitle(of sessionID: String, to title: String) throws {
    guard let old = try db.first(
      "SELECT title FROM piSessionStates WHERE id = ?", [PiSessionState.recordID(sessionID: sessionID)], { $0.text(0) })
    else { return }
    let (from, to) = (Self.taskTitle(old), Self.taskTitle(title))
    guard from != to else { return }
    try db.run(
      "UPDATE cards SET body = ?, modifiedAt = ? WHERE id = ? AND piSessionID = ? AND body = ?",
      [to, Date.stamp, Self.sessionTaskID(sessionID), sessionID, from])
  }

  /// 删掉这些会话的记录，连同为它们自动建的任务（还绑着它的）。必须在写事务内调用。
  func dropSessionRecords(where condition: String, _ arguments: [any SQLBindable]) throws {
    let sessions = try db.query("SELECT sessionID FROM piSessionStates WHERE \(condition)", arguments) { $0.text(0) }
    guard !sessions.isEmpty else { return }
    try db.run("DELETE FROM piSessionStates WHERE \(condition)", arguments)
    for session in sessions {
      _ = try Self.purgeCards(where: "id = ? AND piSessionID = ?", [Self.sessionTaskID(session), session], in: db)
    }
  }
}
