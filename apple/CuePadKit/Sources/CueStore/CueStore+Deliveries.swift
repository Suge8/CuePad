import CueText
import Foundation

extension CueStore {
  /// 手机端：写一条投送请求，等 `host` 指定的那台 Mac 执行。必须指定：只有被指定的 Mac 会领取，
  /// 所以同一请求不会被多台 Mac 各执行一次。`host` 取自该目标 Pi 会话的 `PiSessionState.hostID`。
  /// `cue` 为真是 Cue 写的（`DeliveryOrigin.cue`）。
  @discardableResult
  public func requestDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode = .send, card: UUID? = nil, cue: Bool = false
  ) throws -> DeliveryRequest {
    try write { try insertDelivery(content, to: target, on: host, mode: mode, card: card, cue: cue) }
  }

  /// `requestDelivery` 的事务内部分：必须在写事务内调用。带着任务里的卡开新会话或交话，是叶子换会话的那一刻：
  /// 这件事里没人再用的会话随之结束（`endUnusedSessions`）。你对会话说的话（作答、重跑也算）当场收起挂在它上面的提问（`questionsOn`），
  /// 算你在那边答了：不交给 Cue、不叫醒它；待回复不用写，读的时候就不算了（`sessionsAwaitingReply`）。
  func insertDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode, card: UUID? = nil, cue: Bool
  ) throws -> DeliveryRequest {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    let now = Date.stamp
    let request = DeliveryRequest(
      id: UUID(), content: content, target: target, hostID: host, mode: .known(mode), cardID: card,
      status: .known(.pending), failureReason: nil, handledBy: nil, createdAt: now, completedAt: nil, modifiedAt: now,
      resultReceivedAt: nil, origin: cue ? .known(.cue) : nil)
    try insert(request)
    try registerAttachments(in: content)
    if !cue, DeliveryMode.toSession.contains(mode), target.kind == .known(.piSession), let session = target.ref {
      let on = try questionsOn(session)
      _ = try endQuestions(setAsideBy: request.id, where: on.predicate, on.bindings)
    }
    if let card, mode == .start || DeliveryMode.toSession.contains(mode), let leaf = try leaf(holding: card) {
      try endUnusedSessions(of: leaf, cue: cue)
    }
    return request
  }

  /// 卡所在的叶子：任务干活的叶子（`homeLeaf`）；灵感为 nil。
  private func leaf(holding card: UUID) throws -> UUID? {
    guard try link(of: card)?.isTask == true else { return nil }
    return try homeLeaf(card)
  }

  /// 请 `host` 那台 Mac 回答 `target` 会话正在等的弹窗：与发送共用投送请求与执行器，方式是 `answer`。
  public func requestAnswer(_ answer: PiAnswer, to target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try requestDelivery(answer.stored, to: target, on: host, mode: .answer, cue: cue)
  }

  /// 请 `host` 那台 Mac 改 `target` 会话的模型与思考强度：与发送共用投送请求与执行器，方式是 `config`。
  public func requestConfig(_ config: PiConfig, to target: SendTarget, on host: String) throws -> DeliveryRequest {
    try requestDelivery(config.stored, to: target, on: host, mode: .config)
  }

  /// 请 `host` 那台 Mac 结束 `target` 会话：与发送共用投送请求与执行器，方式是 `end`。
  /// 已有一条还在路上的结束请求时返回它，不再写第二条（连点、两个界面同时点都只发一次）。
  public func requestEnd(of target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestControl(.end, of: target, on: host, cue: cue) }
  }

  /// 请 `host` 那台 Mac 停止 `target` 会话正在跑的这一轮：方式是 `stop`；同样复用还在路上的那一条。
  public func requestStop(of target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestControl(.stop, of: target, on: host, cue: cue) }
  }

  /// 请 `host` 那台 Mac 把 `target` 会话出错的那一轮原样重跑一遍：方式是 `retry`；同样复用还在路上的那一条（连点只发一次）。
  public func requestRetry(of target: SendTarget, on host: String) throws -> DeliveryRequest {
    try write { try requestControl(.retry, of: target, on: host, cue: false) }
  }

  /// 正文就是方式名的控制类请求（结束、停止、重跑）：同一会话同一种方式在路上只有一条。必须在写事务内调用。
  func requestControl(_ mode: DeliveryMode, of target: SendTarget, on host: String, cue: Bool) throws -> DeliveryRequest {
    if let ref = target.ref, let open = try deliveryRequests(toSession: ref).last(where: { $0.mode == .known(mode) && $0.isOpen }) {
      return open
    }
    return try insertDelivery(mode.rawValue, to: target, on: host, mode: mode, cue: cue)
  }

  /// 请 `host` 那台 Mac 开一个新 Pi 会话（后台托管）。`title` 是给人看的目标名（项目名或任务名）。
  /// 给了 `card`（从灵感或任务"新会话"发给 Agent）：会话开好、带着这次的 `token` 记下时，它关联到那个会话（`claimLaunchedCards`）；
  /// 会话名按它定（`sessionName(forCard:)`）。`cue` 为真时请求标明来自 Cue（`DeliveryOrigin`）。
  public func requestLaunch(_ launch: PiLaunch, title: String, on host: String, card: UUID? = nil, cue: Bool = false) throws -> DeliveryRequest {
    var launch = launch
    launch.name = try card.flatMap(sessionName(forCard:))
    return try requestDelivery(
      launch.stored, to: SendTarget(kind: .piSession, name: title, ref: nil), on: host, mode: .start, card: card, cue: cue)
  }

  /// 从这张卡开的新会话叫什么（唯一的规则，`requestLaunch` 与 `handOffPlan` 都读它）：任务的标题，超长的截断（`CueName.clipped`）；
  /// 灵感、没有标题的任务为 nil（Pi 的默认名）。
  func sessionName(forCard card: UUID) throws -> String? {
    guard let card = try find(Card.self, card), card.isTask, !card.heading.isEmpty else { return nil }
    return CueName.clipped(card.heading)
  }

  /// 开新会话的请求（`deliveryRequests` 里的一行）还没等到那个会话的记录：认领（`claimLaunchedCards`）要等它。
  static let launchUnclaimed = "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.launchToken = \(launchToken("deliveryRequests")))"

  /// 开新会话请求（表 `alias` 里的一行）带的认领标识：会话记下的 `PiSessionState.launchToken` 与它相等就是这次开的。
  static func launchToken(_ alias: String) -> String {
    "CASE WHEN json_valid(\(alias).content) THEN json_extract(\(alias).content, '$.token') END"
  }

  /// 请求（表 `alias` 里的一行）是它那张卡最近一次交给（`handedSessions`、认领、`launchingLeaves` 只认这一次）。
  static func latestHandoff(_ alias: String) -> String {
    "\(alias).createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = \(alias).cardID)"
  }

  /// 认领：最近一次是"开新会话"请求的灵感与任务，等那个会话带着请求里的 `token` 记下（`PiSessionState.launchToken`）时
  /// 关联到它，任务同时进行中——与发给已有会话后 `recordSend` 的结果一样。会话记录在本机写下（Mac 的记录器）或同步过来时都在这里认领。
  /// 只认最近一次：带 `cardID` 的请求都是发给 Agent，之后又交给了别处就以那次为准，旧的新会话开好也不抢回（同 `handedSessions`）。
  /// 绑定、解绑会话也算之后的一次交给：它们把指向这张卡的开新会话请求作废（`bindSession`、`unbindSession`）。
  func claimLaunchedCards() throws {
    try db.run(
      """
      UPDATE cards SET \(Self.keepingFormerSession("s.sessionID")), piSessionID = s.sessionID, modifiedAt = ?1,
        startedAt = CASE WHEN cards.todoAt IS NOT NULL THEN COALESCE(cards.startedAt, ?1) END,
        completedAt = CASE WHEN cards.todoAt IS NOT NULL THEN NULL END
      FROM deliveryRequests r JOIN piSessionStates s ON s.launchToken = \(Self.launchToken("r"))
      WHERE r.cardID = cards.id AND r.mode = '\(DeliveryMode.start.rawValue)' AND \(Self.latestHandoff("r"))
        AND cards.piSessionID IS NOT s.sessionID
      """, [Date.stamp])
  }

  /// 请 `host` 那台 Mac 给项目绑定文件夹（`PiBind.folder` 为 nil 是解除）：手机没有完整路径，由 Mac 解析并写本机的目录绑定。
  /// `title` 是项目名（给人看的目标名）。
  public func requestBind(_ bind: PiBind, title: String, on host: String) throws -> DeliveryRequest {
    try requestDelivery(bind.stored, to: SendTarget(kind: .mac, name: title, ref: nil), on: host, mode: .bind)
  }

  /// 请 `host` 那台 Mac 整理技能与规则（`orders` 是那几件，一键整理是 `AgentLibrary.automaticOrders`）。
  public func requestTidy(_ orders: [TidyOrder], on host: String) throws -> DeliveryRequest {
    try requestDelivery(JSONColumn.encode(orders), to: SendTarget(kind: .mac, name: String(localized: "技能与规则"), ref: nil), on: host, mode: .tidy)
  }

  /// 请 `host` 那台 Mac 把一份技能或规则文件写成 `edit.text`（`title` 是它的名字，给人看的目标名）。
  public func requestLibraryEdit(_ edit: LibraryEdit, title: String, on host: String) throws -> DeliveryRequest {
    try requestDelivery(edit.stored, to: SendTarget(kind: .mac, name: title, ref: nil), on: host, mode: .libraryEdit)
  }

  /// 所有投送请求，最近的在前。
  public func deliveryRequests() throws -> [DeliveryRequest] {
    try select(DeliveryRequest.self, orderBy: "createdAt DESC, rowid DESC")
  }

  public func deliveryRequest(_ id: UUID) throws -> DeliveryRequest? { try find(DeliveryRequest.self, id) }

  /// Cue 写的、方式在 `modes` 里的请求（还在库里的，请求完成一会儿就清理）。
  public func cueRequests(_ modes: Set<DeliveryMode>) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "origin = '\(DeliveryOrigin.cue.rawValue)' AND mode IN (\(sqlList(modes)))", orderBy: "createdAt, rowid")
  }

  /// Cue 开出的新会话：Cue 写的开新会话请求（还在库里的）按认领标识对上的会话记录，时刻是那条记录写下的时候（开它的那台 Mac 的时钟）。
  /// 请求写下时会话还没有，对上记录才算开出来了。
  public func cueOpenedSessions() throws -> [CueOpenedSession] {
    try db.query(
      """
      SELECT s.sessionID, r.cardID, s.createdAt FROM deliveryRequests r
        JOIN piSessionStates s ON s.launchToken = \(Self.launchToken("r"))
      WHERE r.origin = '\(DeliveryOrigin.cue.rawValue)' AND r.mode = '\(DeliveryMode.start.rawValue)'
      ORDER BY s.createdAt
      """
    ) { CueOpenedSession(session: $0.text(0), card: $0.uuidOrNil(1), at: $0.date(2)) }
  }

  /// 等到投送请求有结果（已送达或没能送达）：订阅库的变化，别的进程（执行它的 Mac 上的 App、同步拉回的结果）写下也收得到。
  /// 请求在等待期间被撤回、清理时抛 `CueStoreError.notFound`。
  public nonisolated func outcome(of request: DeliveryRequest) async throws -> DeliveryRequest {
    for try await current in observe({ try $0.latest(of: request) }) {
      guard let current else { throw CueStoreError.notFound }
      if !current.isOpen { return current }
    }
    throw CancellationError()
  }

  /// 投送请求此刻的样子：记录还在就是它；发出的话已成了对话里的消息（之后请求被收走，见 `markPushed`）就是已送达；
  /// 都不是（撤回、清理了）为 nil。
  public func latest(of request: DeliveryRequest) throws -> DeliveryRequest? {
    if let current = try deliveryRequest(request.id) { return current }
    guard try db.first("SELECT 1 FROM piMessages WHERE deliveryID = ?", [request.id], { _ in true }) != nil else { return nil }
    var arrived = request
    arrived.status = .known(.succeeded)
    return arrived
  }

  /// 发给一个 Pi 会话（按 Pi 的会话 id）的所有投送请求，先发的在前。
  public func deliveryRequests(toSession sessionID: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND targetRef = ?", [sessionID],
      orderBy: "createdAt, rowid")
  }

  /// 删掉一条请求（移除、重发没能送达的话）：这句收起的提问放回"等你"，它没说到会话那边。
  public func deleteDelivery(_ id: UUID) throws {
    try write {
      try db.run("DELETE FROM deliveryRequests WHERE id = ?", [id])
      try reopen(where: "setAsideBy = ?", [id])
    }
  }

  /// 撤回一条还没被 Mac 领取的请求（`isWithdrawable`）；返回是否撤回了。与领取同一个条件（status = 'pending'），
  /// 所以撤回与领取只有一个能成：已领取的（交给了 Pi）撤不回。这句收起的提问放回"等你"（同 `deleteDelivery`）。
  public func withdrawDelivery(_ id: UUID) throws -> Bool {
    try write {
      try db.run("DELETE FROM deliveryRequests WHERE id = ? AND status = 'pending'", [id])
      guard db.changes > 0 else { return false }
      try reopen(where: "setAsideBy = ?", [id])
      return true
    }
  }
}
