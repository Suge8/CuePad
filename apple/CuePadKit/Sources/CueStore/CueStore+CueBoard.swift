import CueText
import Foundation

extension CueStore {
  /// 看板在不在做事（`CueBoard.active` 不为空）：有不归没做完的事的活会话，或有在做的事（`CueBoardItem.isActive`）。
  /// 不读整块看板、有活会话就不看各件事：值班的 Cue 管理器每次会话状态变化都读它（读整块看板曾占会话忙时常驻开销的一成多）。
  public func cueBoardActive() throws -> Bool {
    try db.first("SELECT 1 FROM piSessionStates WHERE \(Self.isLoose("piSessionStates")) LIMIT 1") { _ in true } != nil
      || boardItems(try topTasks(where: Self.onBoard)).contains(where: \.isActive)
  }

  /// 看板：所有没做完的顶层任务（没删除、没归档），按项目顺序，同项目按手动顺序；加上不归没做完的事的活会话（`isLoose`）。
  /// 在做的（`CueBoard.active`）是值班的 Cue 管的，其余是你手上的清单（Cue 巡视时看）。信封、变化、peek 与推进中都按它。
  public func cueBoard() throws -> CueBoard {
    CueBoard(
      tasks: try boardItems(try topTasks(where: Self.onBoard)),
      sessions: try select(PiSessionState.self, where: Self.isLoose("piSessionStates"), orderBy: "stateSince DESC, id"))
  }

  /// 最近完成、绑过会话的 `limit` 件顶层任务（没删除，归档了的也算），最近完成的在前，各带它（自己或子任务）的会话里最近有动静的那个此刻的样子：
  /// Cue 据此找能接着用的旧会话（不带参数的 peek 末尾列出）。会话记录还没到的不列。
  public func cueRecentlyDone(limit: Int) throws -> [(task: Card, session: PiSessionState)] {
    try topTasks(where: "t.completedAt IS NOT NULL AND \(Self.hasSession)", orderBy: Self.recentlyDone, limit: limit)
      .compactMap { task in try latestSession(of: task.id).map { (task, $0) } }
  }

  /// 表 `alias`（会话记录）里不归没做完的事的活会话：没结束，没有没做完的任务绑着它，
  /// 也不是哪个没做完的任务以前用过的（`Card.formerSessionIDs`）。只有已完成的事绑着的算在内：它还活着，Cue 管它。
  /// 离开了看板的任务（`taskOpen`：归档、删除、项目进了回收站）不算。
  static func isLoose(_ alias: String) -> String {
    """
    \(PiWorkState.outsideSQL([.ended], column: "\(alias).state"))
      AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.piSessionID = \(alias).sessionID AND \(taskOpen))
      AND NOT EXISTS (
        SELECT 1 FROM cards c, json_each(c.formerSessionIDs) f
        WHERE c.formerSessionIDs IS NOT NULL AND \(taskOpen) AND f.value = \(alias).sessionID)
    """
  }

  private func boardItems(_ tasks: [Card]) throws -> [CueBoardItem] {
    guard !tasks.isEmpty else { return [] }
    let links = try CardLinks(db, around: tasks.map(\.id))
    let homes = try cards(Set(tasks.map { links.home(of: $0.id) }))
    let lastDone = try lastCompletedSteps(of: tasks.filter { task in homes[links.home(of: task.id)].map { $0.id != task.id && $0.completedAt != nil } ?? false })
    // 每件事的候选：没做完的叶子（并行做的几步都在），加上没有在做的子任务时落回的那一个
    let steps = Dictionary(grouping: try select(
      Card.self, where: "parentID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL AND completedAt IS NULL",
      [Self.idList(tasks.map(\.id))], orderBy: "sortKey, id"
    ), by: { $0.parentID! })
    let fallback = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, lastDone[$0.id] ?? homes[links.home(of: $0.id)] ?? $0) })
    let candidates = tasks.map { task in (steps[task.id] ?? []) + [fallback[task.id]!] }
    let all = candidates.flatMap { $0 }
    let sessions = try sessionStates(all.compactMap(\.piSessionID))
    let progress = try subtaskProgress(of: tasks.map(\.id))
    let launching = try launchingLeaves(all.map(\.id))
    let sending = try sendingLeaves(all.filter { $0.piSessionID == nil }.map(\.id))
    return zip(tasks, candidates).map { task, candidates in
      let leaves = candidates.map { leaf in
        let session = leaf.piSessionID.flatMap { sessions[$0] }
        return CueBoardLeaf(
          leaf: leaf, session: session, launching: launching.contains(leaf.id), sending: sending.contains(leaf.id),
          since: session?.stateSince ?? leaf.startedAt ?? task.startedAt ?? task.todoAt ?? task.createdAt)
      }
      let open = leaves.dropLast().filter(\.isActive)
      return CueBoardItem(task: task, progress: progress[task.id], leaves: open.isEmpty ? [leaves.last!] : Array(open))
    }
  }

  /// 这些任务各自最后做完的那一步（同一时刻做完的取排在后面的），按任务 id。
  private func lastCompletedSteps(of tasks: [Card]) throws -> [UUID: Card] {
    guard !tasks.isEmpty else { return [:] }
    let steps = try select(
      Card.self, where: "parentID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL AND completedAt IS NOT NULL",
      [Self.idList(tasks.map(\.id))], orderBy: "completedAt, sortKey, id")
    return Dictionary(steps.compactMap { step in step.parentID.map { ($0, step) } }, uniquingKeysWith: { _, later in later })
  }

  /// 看板上的：没做完、没归档。
  private static let onBoard = "t.completedAt IS NULL AND t.archivedAt IS NULL"

  /// 顶层任务 `t` 自己或它的子任务绑着会话。
  static let hasSession = """
    EXISTS (SELECT 1 FROM cards l WHERE (l.id = t.id OR l.parentID = t.id) AND l.todoAt IS NOT NULL AND l.deletedAt IS NULL AND l.piSessionID IS NOT NULL)
    """

  /// 一件事的细节；给子任务也行，按它的顶层任务给。`rounds` 是每个叶子带几轮最近的问答。
  public func cueTaskDetail(_ task: UUID, rounds: Int = 3) throws -> CueTaskDetail {
    let top = try topTask(of: task)
    guard let card = try find(Card.self, top) else { throw CueStoreError.notFound }
    let leaves = try leaves(of: card)
    let sessions = try sessionStates(leaves.compactMap(\.piSessionID))
    let sending = try sendingLeaves(leaves.filter { $0.piSessionID == nil }.map(\.id))
    let details = try leaves.map { leaf in
      CueLeafDetail(
        leaf: leaf, session: try leaf.piSessionID.flatMap { sessions[$0] }.map { try sessionDetail($0, rounds: rounds) },
        sending: sending.contains(leaf.id))
    }
    return CueTaskDetail(task: card, progress: try subtaskProgress(of: [top])[top], leaves: details)
  }

  /// 一个会话的细节（Cue 的 peek 给会话时）；没有记录为 nil。
  public func cueSessionDetail(_ sessionID: String, rounds: Int = 3) throws -> CueSessionDetail? {
    try sessionState(sessionID).map { try sessionDetail($0, rounds: rounds) }
  }

  private func sessionDetail(_ session: PiSessionState, rounds: Int) throws -> CueSessionDetail {
    let recent = try select(
      PiChatMessage.self, where: "sessionID = ? AND role IN ('\(PiChatRole.user.rawValue)', '\(PiChatRole.pi.rawValue)')", [session.sessionID],
      orderBy: "seq DESC, id DESC", limit: rounds * 2
    ).reversed()
    return CueSessionDetail(
      session: session, recent: Array(recent), cueSent: try cueSentDeliveries(among: recent.compactMap(\.deliveryID)))
  }

  /// Cue 说的会话：会话 id、至少 4 位的 id 前缀，或会话名（不分大小写）；id 对上的优先，都按最近有动静的在前。
  public func sessions(matching ref: String) throws -> [PiSessionState] {
    let key = ref.trimmingCharacters(in: .whitespaces)
    let byID = try select(
      PiSessionState.self, where: "sessionID = ?1 OR (length(?1) >= 4 AND sessionID >= ?1 AND sessionID < ?1 || '~')", [key],
      orderBy: "stateSince DESC, id")
    if !byID.isEmpty { return byID }
    return try select(PiSessionState.self, where: "title = ? COLLATE NOCASE", [key], orderBy: "stateSince DESC, id")
  }


  /// 一件顶层任务的交付物（唯一的规则）：它与它的子任务用过的会话（正在用的与换下来的，`Card.formerSessionIDs`）
  /// 在任务开工（`Card.startedSQL`，没开始过按排进待办的时刻）之后发到手机的预览，从早到晚。开工前的不算：会话被另一件事接着用时，前一件的图不会算到这件上。
  /// 不另记"哪些是交付物"：会话发到手机本来就是给人看的。Cue 在 peek 里看这份清单，做完时从中点名要挂在结果上的几张（`finishTask` 的 shots）。
  public func deliverables(of task: UUID) throws -> [PiPreview] {
    try db.query(
      """
      WITH used(session) AS (
        SELECT piSessionID FROM cards
        WHERE (id = ?1 OR parentID = ?1) AND todoAt IS NOT NULL AND deletedAt IS NULL AND piSessionID IS NOT NULL
        UNION SELECT f.value FROM cards c, json_each(c.formerSessionIDs) f
        WHERE (c.id = ?1 OR c.parentID = ?1) AND c.todoAt IS NOT NULL AND c.deletedAt IS NULL AND c.formerSessionIDs IS NOT NULL)
      SELECT DISTINCT \(PiPreview.columns.map { "p.\($0)" }.joined(separator: ", "))
      FROM previews p JOIN used u ON u.session = p.sessionID JOIN cards t ON t.id = ?1
      WHERE p.createdAt >= COALESCE(\(Card.startedSQL("t")), t.todoAt)
      ORDER BY p.createdAt, p.id
      """, [task]
    ) { PiPreview(row: $0) }
  }

  func topTasks(
    where condition: String, _ arguments: [any SQLBindable] = [], orderBy: String? = nil, limit: Int? = nil
  ) throws -> [Card] {
    try db.query(
      """
      SELECT \(Card.selection(as: "t")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE t.parentID IS NULL AND t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND (p.id IS NULL OR p.deletedAt IS NULL)
        AND \(condition)
      ORDER BY \(orderBy ?? "\(Self.taskProjectOrder), t.sortKey, t.id") LIMIT ?
      """, arguments + [limit ?? -1]
    ) { Card(row: $0) }
  }

  private func cards(_ ids: Set<UUID>) throws -> [UUID: Card] {
    Dictionary(
      uniqueKeysWithValues: try select(Card.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)]).map { ($0.id, $0) })
  }

  func sessionStates(_ sessionIDs: [String]) throws -> [String: PiSessionState] {
    guard !sessionIDs.isEmpty else { return [:] }
    return Dictionary(
      try select(PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(sessionIDs)]).map { ($0.sessionID, $0) },
      uniquingKeysWith: { first, _ in first })
  }
}
