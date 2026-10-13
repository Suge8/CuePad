import CueText
import Foundation

// 任务交给会话、跟进与看板：界面与 Cue（经 MCP）共用这一份规则。`cue` 为真的写入标明来自 Cue（`DeliveryOrigin`）。

/// 交给会话的结果：发进了叶子绑着的会话，或开了新会话（请求正文是 `PiLaunch`，会话开好后叶子认领它）。
public enum CueHandOff: Equatable, Sendable {
  case sent(DeliveryRequest)
  case started(DeliveryRequest)

  public var request: DeliveryRequest {
    switch self {
    case .sent(let request), .started(let request): request
    }
  }
}

/// Cue 眼里的一个项目（`CueStore.cueProjects`）。
public struct CueProject: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  /// 绑了文件夹（开得了会话）。
  public var hasFolder: Bool

  public init(id: UUID, name: String, hasFolder: Bool) {
    self.id = id
    self.name = name
    self.hasFolder = hasFolder
  }
}

/// 看板上的一件事：Cue 跟进的一个顶层任务。
public struct CueBoardItem: Identifiable, Equatable, Sendable {
  public var task: Card
  /// 步骤完成了几个；没有步骤为 nil。
  public var progress: TaskProgress?
  /// 此刻在做的叶子：没有步骤是任务自己，否则第一个没完成的步骤（没有就第一个）。
  public var leaf: Card
  /// 叶子的会话记录；还没开会话（或记录还没到）为 nil。
  public var session: PiSessionState?
  /// 正在为叶子开新会话（请求还没执行完，或开好了还没认领到）。
  public var launching: Bool
  /// 停在当前状态的起点：会话进入当前状态的时刻，没有会话时是开始做或设为任务的时刻。
  public var since: Date
  public var id: UUID { task.id }
}

/// 某时刻之后，Cue 跟进的事里的一处变化。
public struct CueChange: Equatable, Sendable {
  public enum Kind: String, Sendable, CaseIterable {
    /// 会话歇下（这一轮做完）
    case settled
    /// 会话在等回答
    case waitingForUser
    /// 会话出错
    case failed
    /// 叶子或任务完成
    case done
    /// 你在会话里亲自说了话（在终端里打的）
    case youSpoke
    /// 你把这件事交给 Cue 跟进
    case joined
    /// 不再由 Cue 跟进：你接手了、删了、归档了等（`detail` 说明）；完成了的只报 `done`
    case left
  }

  public var kind: Kind
  /// 顶层任务的 id。
  public var taskID: UUID
  /// 顶层任务；已永久删除（只会是 `left`）为 nil。
  public var task: Card?
  /// 变化所在的叶子；任务本身的变化为 nil。
  public var leaf: Card?
  public var at: Date
  /// 提问、错误、你说的话、为什么不再跟进。
  public var detail: String?
  /// 会话记录里已有的摘要：叶子的会话的；任务本身的变化取它最近有动静的那个会话的。
  public var recap: PiRecap?

  init(kind: Kind, task: Card, leaf: Card? = nil, at: Date, detail: String? = nil, recap: PiRecap? = nil) {
    self.init(kind: kind, taskID: task.id, task: task, leaf: leaf, at: at, detail: detail, recap: recap)
  }

  init(kind: Kind, taskID: UUID, task: Card?, leaf: Card?, at: Date, detail: String?, recap: PiRecap?) {
    self.kind = kind
    self.taskID = taskID
    self.task = task
    self.leaf = leaf
    self.at = at
    self.detail = detail
    self.recap = recap
  }
}

/// 一件事的细节（Cue 的 peek）：叶子、各自的草稿、会话、最近几轮问答与预览。
public struct CueTaskDetail: Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  public var leaves: [CueLeafDetail]
}

public struct CueLeafDetail: Equatable, Sendable {
  public var leaf: Card
  public var draft: Card?
  public var session: PiSessionState?
  /// 最近几轮问答（你说的与 Pi 的回答），从早到晚。
  public var recent: [PiChatMessage]
  public var previews: [PiPreview]
}

extension Card {
  /// 标题（`CueSummary` 的规则）。不公开：App 有自己的 `title`（空白时的占位说法）。
  var title: String { CueSummary(body).title }
}

extension CueStore {
  // MARK: 交给会话

  /// 把话交给叶子（没有步骤的任务）的会话：叶子绑着会话就发进那个会话（会话在别的 Mac 就写那台的 `hostID`）；
  /// 没绑就在项目绑定的文件夹开一个以叶子标题命名的新会话，话作为第一句。`text` 为 nil 时交出叶子的草稿（提示词），
  /// 送达后草稿用掉（`PromptConsumption`）。`host` 是这台 Mac：会话记录不在时、项目在这台 Mac 上绑了文件夹时用它。
  /// `mode` 是说话的方式（`send` / `steer` / `followUp`）：直接发送而会话正忙时不写请求，抛 `sessionBusy`。
  /// 项目没绑文件夹抛 `noFolder`。`model` 与 `thinking` 只用于开新会话。
  public func handOff(
    _ leaf: UUID, text: String? = nil, mode: DeliveryMode = .send, model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil,
    host: String, cue: Bool = false
  ) throws -> CueHandOff {
    let card = try requireLeaf(leaf)
    let draft = try Self.draft(of: leaf, in: db).flatMap { try find(Card.self, $0) }
    let content = text ?? draft.map { CueFormat.readable(CueVariables.fill($0.body, values: $0.variableValues)) } ?? ""
    let carrier = text == nil ? draft?.id ?? leaf : leaf
    if let sessionID = card.piSessionID {
      let state = try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))
      if mode == .send, state?.state.known?.isTurnRunning == true { throw CueStoreError.sessionBusy }
      let target = SendTarget(kind: .piSession, name: state?.title ?? card.title, ref: sessionID)
      return .sent(try requestDelivery(content, to: target, on: state?.hostID ?? host, mode: mode, card: carrier, cue: cue))
    }
    guard try launchingLeaves([leaf]).isEmpty else { throw CueStoreError.launching(card.title) }
    guard let project = card.projectID else { throw CueStoreError.noFolder("") }
    guard let launchHost = try launchHost(for: project, preferring: host) else {
      throw CueStoreError.noFolder(try find(Project.self, project)?.name ?? "")
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let launch = PiLaunch(project: project, prompt: trimmed.isEmpty ? nil : content, token: UUID().uuidString, name: card.title, model: model, thinking: thinking)
    return .started(try requestLaunch(launch, title: card.title, on: launchHost, card: carrier, cue: cue))
  }

  /// 这些叶子里正在开新会话的：带着叶子或它的草稿（交出草稿时请求带的是草稿，送达后改记到叶子上）的开新会话请求还在路上，
  /// 或成功了、会话记录还没到（还没认领）。
  public func launchingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    guard !leaves.isEmpty else { return [] }
    return Set(try db.query(
      """
      WITH leaves(id) AS (SELECT value FROM json_each(?))
      SELECT CASE WHEN deliveryRequests.cardID IN leaves THEN deliveryRequests.cardID ELSE c.parentID END
      FROM deliveryRequests LEFT JOIN cards c ON c.id = deliveryRequests.cardID AND c.todoAt IS NULL
      WHERE (deliveryRequests.cardID IN leaves OR c.parentID IN leaves) AND deliveryRequests.mode = 'start'
        AND deliveryRequests.status IN ('pending', 'executing', 'succeeded') AND \(Self.launchUnclaimed)
      """, [Self.idList(leaves)]) { $0.uuid(0) })
  }

  /// 项目在哪台 Mac 上绑了文件夹：这台 Mac 绑了就是它，否则别的 Mac 里按名字排第一台；都没绑为 nil。
  private func launchHost(for project: UUID, preferring host: String) throws -> String? {
    if try directory(of: project) != nil { return host }
    let hosts = try db.query("SELECT hostID FROM directoryBindings WHERE projectID = ? ORDER BY hostName, hostID", [project]) { $0.text(0) }
    return hosts.contains(host) ? host : hosts.first
  }

  /// 回答叶子的会话正在等的提问：选择框给选项原文或从 1 起的序号，确认框给是或否，输入框给文字。
  public func answerLeaf(_ leaf: UUID, _ value: String, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let (card, state) = try requireSession(of: leaf)
    guard let question = state?.question, question.isAnswerable, let promptID = question.promptID, let kind = question.kind.known else {
      throw CueStoreError.nothingToAnswer
    }
    let answer = try Self.answerValue(value.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, options: question.options)
    let target = SendTarget(kind: .piSession, name: state?.title ?? card.title, ref: card.piSessionID)
    return try requestAnswer(PiAnswer(promptID: promptID, value: answer), to: target, on: state?.hostID ?? host, cue: cue)
  }

  private static func answerValue(_ value: String, kind: PiQuestionKind, options: [String]) throws -> PiAnswerValue {
    switch kind {
    case .text: return .text(value)
    case .select:
      if let hit = options.first(where: { $0 == value }) ?? options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
        return .option(hit)
      }
      if let number = Int(value), options.indices.contains(number - 1) { return .option(options[number - 1]) }
      throw CueStoreError.invalidAnswer(options)
    case .confirm:
      switch value.lowercased() {
      case "yes", "y", "true", "是", "好", "确认", "ok": return .confirmed(true)
      case "no", "n", "false", "否", "不", "取消": return .confirmed(false)
      default: throw CueStoreError.invalidAnswer(["yes", "no"])
      }
    }
  }

  /// 停止叶子的会话正在跑的这一轮。
  public func stopLeaf(_ leaf: UUID, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let (card, state) = try requireSession(of: leaf)
    return try requestStop(of: SendTarget(kind: .piSession, name: state?.title ?? card.title, ref: card.piSessionID), on: state?.hostID ?? host, cue: cue)
  }

  /// 完成一件事并结束它的会话（写结束请求），返回结束请求。叶子直接完成；有步骤的任务要步骤都完成了才行
  /// （还有没完成的抛 `stepsRemaining`），完成后结束各步骤上还没结束的会话。
  @discardableResult
  public func completeTask(_ task: UUID, host: String, cue: Bool = false) throws -> [DeliveryRequest] {
    guard let link = try link(of: task), let card = try find(Card.self, task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    let steps = try select(Card.self, where: "parentID = ? AND todoAt IS NOT NULL AND deletedAt IS NULL", [task], orderBy: "sortKey, id")
    let remaining = steps.filter { $0.completedAt == nil }.count
    guard remaining == 0 else { throw CueStoreError.stepsRemaining(remaining) }
    try write { _ = try applyStatus(task, .done) }
    return try (steps.isEmpty ? [card] : steps).compactMap { leaf in
      guard let sessionID = leaf.piSessionID else { return nil }
      let state = try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))
      guard state?.state != .known(.ended) else { return nil }
      return try requestEnd(of: SendTarget(kind: .piSession, name: state?.title ?? leaf.title, ref: sessionID), on: state?.hostID ?? host, cue: cue)
    }
  }

  /// 这件事由 Cue 跟进（`on`）还是你自己：给步骤也行，记在它的顶层任务上。返回顶层任务。
  @discardableResult
  public func setCueFollows(_ task: UUID, _ on: Bool) throws -> Card {
    try write {
      let top = try topTask(of: task)
      try db.run("UPDATE cards SET cueFollows = ?, modifiedAt = ? WHERE id = ? AND cueFollows != ?", [on, Date.stamp, top, on])
      return try find(Card.self, top)!
    }
  }

  /// 任务此刻在做的叶子：叶子就是它自己，有步骤的是第一个没完成的步骤（没有就第一个）。不是任务抛 `notATask`。
  public func workingLeaf(of task: UUID) throws -> Card {
    guard let link = try link(of: task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    guard let leaf = try find(Card.self, try promptHome(task)) else { throw CueStoreError.notFound }
    return leaf
  }

  /// 任务（或步骤）所在的顶层任务；不是任务抛 `notATask`。
  public func topTask(of task: UUID) throws -> UUID {
    guard let link = try link(of: task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    return try ancestors(of: task).last ?? task
  }

  private func requireLeaf(_ leaf: UUID) throws -> Card {
    guard let link = try link(of: leaf), let card = try find(Card.self, leaf) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    guard try promptHome(leaf) == leaf else { throw CueStoreError.notALeaf }
    return card
  }

  private func requireSession(of leaf: UUID) throws -> (Card, PiSessionState?) {
    let card = try requireLeaf(leaf)
    guard let sessionID = card.piSessionID else { throw CueStoreError.noSession(card.title) }
    return (card, try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID)))
  }

  // MARK: 看板与变化

  /// 所有项目（没进回收站的，顺序同 `projects()`）与有没有绑文件夹（本机或任何一台 Mac）：Cue 据此知道活能放进哪里、哪里开得了会话。
  public func cueProjects() throws -> [CueProject] {
    let bound = Set(try db.query("SELECT projectID FROM projectDirectories UNION SELECT projectID FROM directoryBindings") { $0.uuid(0) })
    return try projects().map { CueProject(id: $0.id, name: $0.name, hasFolder: bound.contains($0.id)) }
  }

  /// Cue 跟进的、没做完的顶层任务（没删除、没归档），按项目与手动顺序。
  public func cueBoard() throws -> [CueBoardItem] {
    try boardItems(try followedTasks(where: Self.onBoard))
  }

  /// 所有没做完的顶层任务（不论谁在跟进；没删除、没归档），按项目顺序、未分类在最后，同项目按手动顺序：Cue 刚启用和巡视时看你手上有哪些事。
  public func openTopTasks() throws -> [CueBoardItem] {
    try boardItems(try topTasks(followedOnly: false, where: Self.onBoard))
  }

  private func boardItems(_ tasks: [Card]) throws -> [CueBoardItem] {
    guard !tasks.isEmpty else { return [] }
    let links = try CardLinks(db, around: tasks.map(\.id))
    let leaves = try cards(Set(tasks.map { links.home(of: $0.id) }))
    let sessions = try sessionStates(Array(leaves.values.compactMap(\.piSessionID)))
    let progress = try subtaskProgress(scope: "AND parentID IN (SELECT value FROM json_each(?))", [Self.idList(tasks.map(\.id))])
    let launching = try launchingLeaves(Array(leaves.keys))
    return tasks.map { task in
      let leaf = leaves[links.home(of: task.id)] ?? task
      let session = leaf.piSessionID.flatMap { sessions[$0] }
      return CueBoardItem(
        task: task, progress: progress[task.id], leaf: leaf, session: session, launching: launching.contains(leaf.id),
        since: session?.stateSince ?? leaf.startedAt ?? task.startedAt ?? task.todoAt ?? task.createdAt)
    }
  }

  /// 看板上的（跟进中的）：没做完、没归档。
  private static let onBoard = "t.completedAt IS NULL AND t.archivedAt IS NULL"

  /// `since` 之后 Cue 跟进的事里的变化，从早到晚：会话歇下、等回答、出错（按会话进入这个状态的时刻），叶子或任务完成，
  /// 你在会话的终端里亲自说了话。`followed` 是上次醒来时看板上的任务 id：给了就和此刻的看板比，
  /// 多出来的是交给了 Cue（`joined`），少了的是不再跟进（`left`，完成了的只报 `done`）；nil 不比（如管理器刚启动）。
  public func cueChanges(since: Date, followed: Set<UUID>? = nil) throws -> [CueChange] {
    let tasks = try followedTasks(where: "(t.completedAt IS NULL OR t.completedAt > ?)", [since])
    var changes: [CueChange] = []
    if let followed { changes += try membershipChanges(from: followed, since: since, reported: Set(tasks.map(\.id))) }
    if !tasks.isEmpty {
      let steps = Dictionary(
        grouping: try select(
          Card.self, where: "parentID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL",
          [Self.idList(tasks.map(\.id))], orderBy: "sortKey, id"),
        by: { $0.parentID! })
      let leaves = tasks.flatMap { task in (steps[task.id] ?? [task]).map { (task: task, leaf: $0) } }
      let sessions = try sessionStates(leaves.compactMap(\.leaf.piSessionID))
      for task in tasks where task.completedAt.map({ $0 > since }) ?? false {
        changes.append(CueChange(kind: .done, task: task, at: task.completedAt!, recap: try latestRecap(of: task.id)))
      }
      for (task, leaf) in leaves {
        if leaf.id != task.id, let done = leaf.completedAt, done > since {
          changes.append(CueChange(kind: .done, task: task, leaf: leaf, at: done, recap: leaf.piSessionID.flatMap { sessions[$0] }?.recap))
        }
        guard let session = leaf.piSessionID.flatMap({ sessions[$0] }), session.stateSince > since else { continue }
        let (kind, detail): (CueChange.Kind?, String?) =
          switch session.state.known {
          case .settled: (.settled, nil)
          case .waitingForUser: (.waitingForUser, session.question?.text ?? session.detail)
          case .error: (.failed, session.detail)
          default: (nil, nil)
          }
        if let kind { changes.append(CueChange(kind: kind, task: task, leaf: leaf, at: session.stateSince, detail: detail, recap: session.recap)) }
      }
      let bySession = Dictionary(leaves.compactMap { pair in pair.leaf.piSessionID.map { ($0, pair) } }, uniquingKeysWith: { first, _ in first })
      let typed = try select(
        PiChatMessage.self,
        where: "sessionID IN (SELECT value FROM json_each(?)) AND role = '\(PiChatRole.user.rawValue)' AND deliveryID IS NULL AND at > ?",
        [JSONColumn.encode(Array(bySession.keys)), since], orderBy: "at, seq")
      for message in typed {
        guard let pair = bySession[message.sessionID] else { continue }
        changes.append(CueChange(
          kind: .youSpoke, task: pair.task, leaf: pair.leaf, at: message.at, detail: CueFormat.plainText(message.text),
          recap: sessions[message.sessionID]?.recap))
      }
    }
    return changes.sorted { $0.at < $1.at }
  }

  /// 任务（自己或它的步骤）的会话里最近有动静的那个的摘要；没有会话为 nil。
  private func latestRecap(of task: UUID) throws -> PiRecap? {
    try select(
      PiSessionState.self,
      where: "sessionID IN (SELECT piSessionID FROM cards WHERE (id = ?1 OR parentID = ?1) AND todoAt IS NOT NULL AND piSessionID IS NOT NULL)",
      [task], orderBy: "stateSince DESC, id", limit: 1
    ).first?.recap
  }

  /// 跟进集合的差异：此刻看板上有、`followed` 里没有的是 `joined`；反过来的是 `left`，带上原因（永久删除的也报，只有 id）。
  /// 完成了的报 `done`（`reported` 里的已经报过，不重复）。
  private func membershipChanges(from followed: Set<UUID>, since: Date, reported: Set<UUID>) throws -> [CueChange] {
    let current = try followedTasks(where: Self.onBoard)
    var changes = current.filter { !followed.contains($0.id) }.map { CueChange(kind: .joined, task: $0, at: $0.modifiedAt) }
    let gone = followed.subtracting(current.map(\.id))
    let trashedProjects = Set(try select(Project.self, where: "deletedAt IS NOT NULL").map(\.id))
    let remaining = try cards(gone)
    for id in gone where remaining[id] == nil {
      changes.append(CueChange(kind: .left, taskID: id, task: nil, leaf: nil, at: Date.stamp, detail: "删了", recap: nil))
    }
    for card in remaining.values {
      if let done = card.completedAt {
        if !reported.contains(card.id), done > since { changes.append(CueChange(kind: .done, task: card, at: done, recap: try latestRecap(of: card.id))) }
        continue
      }
      let reason =
        if card.deletedAt != nil || card.projectID.map(trashedProjects.contains) == true { "删了" }
        else if card.archivedAt != nil { "归档了" }
        else if card.todoAt == nil { "改回了灵感" }
        else if card.parentID != nil { "挂到了别的任务下" }
        else { "你接手了" }
      changes.append(CueChange(kind: .left, task: card, at: card.modifiedAt, detail: reason))
    }
    return changes
  }

  /// 一件事的细节；给步骤也行，按它的顶层任务给。`rounds` 是每个叶子带几轮最近的问答。
  public func cueTaskDetail(_ task: UUID, rounds: Int = 3) throws -> CueTaskDetail {
    let top = try topTask(of: task)
    guard let card = try find(Card.self, top) else { throw CueStoreError.notFound }
    let steps = try select(Card.self, where: "parentID = ? AND todoAt IS NOT NULL AND deletedAt IS NULL", [top], orderBy: "sortKey, id")
    let leaves = steps.isEmpty ? [card] : steps
    let sessions = try sessionStates(leaves.compactMap(\.piSessionID))
    let details = try leaves.map { leaf in
      let sessionID = leaf.piSessionID
      let recent = try sessionID.map {
        try select(
          PiChatMessage.self, where: "sessionID = ? AND role IN ('\(PiChatRole.user.rawValue)', '\(PiChatRole.pi.rawValue)')", [$0],
          orderBy: "seq DESC, id DESC", limit: rounds * 2
        ).reversed()
      } ?? []
      return CueLeafDetail(
        leaf: leaf, draft: try Self.draft(of: leaf.id, in: db).flatMap { try find(Card.self, $0) },
        session: sessionID.flatMap { sessions[$0] }, recent: Array(recent), previews: try sessionID.map(previews(of:)) ?? [])
    }
    return CueTaskDetail(task: card, progress: try subtaskProgress(of: top)[top], leaves: details)
  }

  private func followedTasks(where condition: String, _ arguments: [any SQLBindable] = []) throws -> [Card] {
    try topTasks(followedOnly: true, where: condition, arguments)
  }

  private func topTasks(followedOnly: Bool, where condition: String, _ arguments: [any SQLBindable] = []) throws -> [Card] {
    try db.query(
      """
      SELECT \(Card.columns.map { "t.\($0)" }.joined(separator: ", ")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE \(followedOnly ? "t.cueFollows = 1 AND" : "") t.parentID IS NULL AND t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND (p.id IS NULL OR p.deletedAt IS NULL)
        AND \(condition)
      ORDER BY t.projectID IS NULL, \(Self.projectOrder("p")), t.sortKey, t.id
      """, arguments
    ) { Card(row: $0) }
  }

  private func cards(_ ids: Set<UUID>) throws -> [UUID: Card] {
    Dictionary(
      uniqueKeysWithValues: try select(Card.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)]).map { ($0.id, $0) })
  }

  private func sessionStates(_ sessionIDs: [String]) throws -> [String: PiSessionState] {
    guard !sessionIDs.isEmpty else { return [:] }
    return Dictionary(
      try select(PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(sessionIDs)]).map { ($0.sessionID, $0) },
      uniquingKeysWith: { first, _ in first })
  }
}
