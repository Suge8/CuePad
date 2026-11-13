import CueText
import Foundation

/// 安全替换与用户确认后的重复意图互斥；未知结果不能冒充可撤回。
public enum SessionLaunchIntent: Sendable {
    case new
    case replacing(UUID)
    case repeatingConfirmed
}

extension CueStore {
  /// 必须指定 `host`：只有被指定的 Mac 会领取，所以同一请求不会被多台 Mac 各执行一次。
  @discardableResult
  public func requestDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode = .send, card: UUID? = nil, cue: Bool = false
  ) throws -> DeliveryRequest {
    try write { try insertDelivery(content, to: target, on: host, mode: mode, card: card, cue: cue) }
  }

  /// 远端快照不能授权删除：沿现有投送通道交给目标 Mac，核对仍未交出后才撤回。
  public func requestDeliveryWithdrawal(_ id: UUID) throws -> DeliveryRequest? {
    try write {
      guard let original = try find(DeliveryRequest.self, id), original.status == .known(.preparing) else { return nil }
      if let existing = try select(DeliveryRequest.self, where: "mode = 'withdraw' AND content = ? AND status IN (\(DeliveryStatus.openSQL))", [id.uuidString.lowercased()]).first {
        return existing
      }
      return try insertDelivery(id.uuidString.lowercased(), to: original.target, on: original.hostID, mode: .withdraw, cue: false)
    }
  }

  /// 带着任务里的卡开新会话或交话，是叶子换会话的那一刻：这件事里没人再用的会话随之结束（`endUnusedSessions`）。你对会话说的话当场收起挂在它上面的提问，算你在那边答了：不交给 Cue、不叫醒它；待回复不用写，读的时候就不算了。
  func insertDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode, card: UUID? = nil, cue: Bool, id: UUID = UUID()
  ) throws -> DeliveryRequest {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    if let session = target.ref, target.kind == .known(.piSession), DeliveryMode.requiresReadySession.contains(mode) {
      try requireSessionAvailable(session)
    }
    let now = Date.stamp
    var request = DeliveryRequest(
      id: id, content: content, target: target, hostID: host, mode: .known(mode), cardID: card,
      status: .known(.pending), reason: nil, handledBy: nil, createdAt: now, completedAt: nil, modifiedAt: now,
      resultReceivedAt: nil, origin: cue ? .known(.cue) : nil)
    if let card, mode == .start || mode == .send || mode == .command {
      let leaf = try link(of: card)?.isTask == true ? homeLeaf(card) : card
      request.cardID = leaf
      request.sessionBindingRevision = try reviseSessionBinding(leaf, explicit: false)
      try beginTask(leaf, at: now)
    }
    try insert(request)
    for key in Set(request.attachmentKeys) { try registerAttachment(key) }
    if !cue, DeliveryMode.toSession.contains(mode), target.kind == .known(.piSession), let session = target.ref {
      let on = try questionsOn(session)
      _ = try endQuestions(setAsideBy: request.id, where: on.predicate, on.bindings)
    }
    // 你对一个会话说话，绑着它的任务就不算做完：回到进行中，这个会话重新有任务在用，不被收尾的复核结束。
    // Cue 的话不算：他问已完成的事只为问清楚，问完收掉会话；真有问题他先 edit reopen（`CuePrompt`）
    if !cue, DeliveryMode.toSession.contains(mode), target.kind == .known(.piSession), let session = target.ref {
      try reopenTasks(spokenToIn: session)
    }
    if let card, mode == .start || DeliveryMode.toSession.contains(mode), let leaf = try leaf(holding: card) {
      try endUnusedSessions(of: leaf, cue: cue)
    }
    return request
  }

  private func leaf(holding card: UUID) throws -> UUID? {
    guard try link(of: card)?.isTask == true else { return nil }
    return try homeLeaf(card)
  }

  public func requestAnswer(_ answer: Answer, to target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try requestDelivery(answer.stored, to: target, on: host, mode: .answer, cue: cue)
  }

  public func requestConfig(_ config: SessionConfig, to target: SendTarget, on host: String) throws -> DeliveryRequest {
    try requestDelivery(config.stored, to: target, on: host, mode: .config)
  }

  /// 已有一条还在路上的结束请求时返回它，不再写第二条（连点、两个界面同时点都只发一次）。
  public func requestEnd(of target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestControl(.end, of: target, on: host, cue: cue) }
  }

  public func requestStop(of target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestControl(.stop, of: target, on: host, cue: cue) }
  }

  public func requestRetry(of target: SendTarget, on host: String) throws -> DeliveryRequest {
    try write { try requestControl(.retry, of: target, on: host, cue: false) }
  }

  /// 同一会话同一种方式在路上只有一条。必须在写事务内调用。
  func requestControl(_ mode: DeliveryMode, of target: SendTarget, on host: String, cue: Bool, content: String? = nil) throws -> DeliveryRequest {
    let content = content ?? mode.rawValue
    if let ref = target.ref, let open = try deliveryRequests(toSession: ref).last(where: { $0.mode == .known(mode) && $0.content == content && Speech.trip($0, at: .always(at: timing.now())).awaitingResult }) {
      return open
    }
    return try insertDelivery(content, to: target, on: host, mode: mode, cue: cue)
  }

  /// 给了 `card`：会话开好、带着这次的 `token` 记下时，它关联到那个会话（`claimLaunchedCards`），会话名按它定。同一任务未收尾的请求禁止冒充首次提交；安全替换同事务撤旧写新，撤不回就拒绝；重复须明确确认。
  public func requestLaunch(
    _ launch: LaunchRequest, title: String, on host: String, card: UUID? = nil, cue: Bool = false, intent: SessionLaunchIntent = .new
  ) throws -> DeliveryRequest {
    try write {
      let previous: UUID? = if case .replacing(let id) = intent { id } else { nil }
      switch intent {
      case .repeatingConfirmed: break
      case .new, .replacing:
        let owner = try card ?? previous.flatMap { try deliveryRequest($0)?.cardID }
        if let owner, try unresolvedLaunches(for: owner).contains(where: { $0.id != previous }) {
          throw CueStoreError.deliveryAlreadyHanded
        }
      }
      if let previous, try !removeFailedDelivery(previous), try !removeUnstartedDelivery(previous, locallyOn: nil) {
        throw CueStoreError.deliveryAlreadyHanded
      }
      var launch = launch
      launch.name = try card.flatMap(sessionName(forCard:))
      if let card, try link(of: card)?.isTask == true { launch.createdForTaskID = try homeLeaf(card) }
      return try insertDelivery(
        launch.stored, to: SendTarget(kind: .piSession, name: title, ref: nil), on: host, mode: .start, card: card, cue: cue)
    }
  }

  /// 所有仍可能开出会话的请求：后来的失败或交接不消除旧风险；与只决定任务归属的 latestHandoff 分开。
  /// 原请求明确失败或已看到其会话时才解除未知风险，不另存风险状态。
  public func unresolvedLaunches(for card: UUID) throws -> [DeliveryRequest] {
    try select(DeliveryRequest.self, where: "cardID = ? AND \(Self.unresolvedLaunch)", [card], orderBy: "createdAt DESC, rowid DESC")
  }

  /// 全库每件任务最新的那次没收尾的开会话请求（规则同 `unresolvedLaunches(for:)`）。
  public func latestUnresolvedLaunches() throws -> [UUID: DeliveryRequest] {
    let requests = try select(DeliveryRequest.self, where: "cardID IS NOT NULL AND \(Self.unresolvedLaunch)", [], orderBy: "createdAt DESC, rowid DESC")
    return Dictionary(requests.compactMap { request in request.cardID.map { ($0, request) } }, uniquingKeysWith: { newer, _ in newer })
  }

  private static let unresolvedLaunch =
    "mode = '\(DeliveryMode.start.rawValue)' AND status != '\(DeliveryStatus.failed.rawValue)' AND \(launchUnclaimed)"

  /// 任务的标题，超长的截断（`CueName.clipped`）；灵感、没有标题的任务为 nil（Pi 的默认名）。
  func sessionName(forCard card: UUID) throws -> String? {
    guard let card = try find(Card.self, card), card.isTask, !card.heading.isEmpty else { return nil }
    return CueName.clipped(card.heading)
  }

  static let launchUnclaimed = "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.launchToken = \(launchToken("deliveryRequests")))"

  static func launchToken(_ alias: String) -> String {
    "CASE WHEN json_valid(\(alias).content) THEN json_extract(\(alias).content, '$.token') END"
  }

  static func latestHandoff(_ alias: String) -> String {
    "\(alias).createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = \(alias).cardID)"
  }

  /// 会话创建来源与关联同事务认领。来源按启动请求固定；关联沿用请求发起时的修订，明确改绑或解绑后旧请求只登记来源。
  func claimLaunchedCards() throws {
    let requests = try select(DeliveryRequest.self, where: """
      mode = 'start' AND EXISTS (
        SELECT 1 FROM piSessionStates s LEFT JOIN cards c ON c.id = deliveryRequests.cardID
        WHERE s.launchToken = \(Self.launchToken("deliveryRequests")) AND (
          (s.createdForTaskID IS NULL AND json_extract(deliveryRequests.content, '$.createdForTaskID') IS NOT NULL)
          OR (json_extract(c.sessionBindingRevision, '$.id') = json_extract(deliveryRequests.sessionBindingRevision, '$.id') AND c.piSessionID IS NOT s.sessionID)))
      """)
    for request in requests {
      guard let launch = request.launch,
        let session = try select(SessionState.self, where: "launchToken = ?", [launch.token]).first else { continue }
      try recordSessionCreationInTransaction(session.sessionID, from: request)
      try linkDeliveredCardInTransaction(request, toSession: session.sessionID)
    }
  }

  public func requestBind(_ bind: BindRequest, title: String, on host: String) throws -> DeliveryRequest {
    try requestDelivery(bind.stored, to: SendTarget(kind: .mac, name: title, ref: nil), on: host, mode: .bind)
  }

  public func requestTidy(_ orders: [TidyOrder], on host: String) throws -> DeliveryRequest {
    try requestDelivery(JSONColumn.encode(orders), to: SendTarget(kind: .mac, name: String(localized: "技能与规则"), ref: nil), on: host, mode: .tidy)
  }

  public func requestLibraryEdit(_ edit: LibraryEdit, title: String, on host: String) throws -> DeliveryRequest {
    try requestDelivery(edit.stored, to: SendTarget(kind: .mac, name: title, ref: nil), on: host, mode: .libraryEdit)
  }

  public func deliveryRequests() throws -> [DeliveryRequest] {
    let requests = try select(DeliveryRequest.self, orderBy: "createdAt DESC, rowid DESC")
    let now = timing.now()
    for request in requests {
      if let due = Speech.deadline(request), due > now { expire(at: due) }
    }
    return requests
  }

  public func deliveryRequest(_ id: UUID) throws -> DeliveryRequest? { try find(DeliveryRequest.self, id) }

  public func cueRequests(_ modes: Set<DeliveryMode>) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "origin = '\(DeliveryOrigin.cue.rawValue)' AND mode IN (\(sqlList(modes)))", orderBy: "createdAt, rowid")
  }

  /// 请求写下时会话还没有，对上记录才算开出来了；时刻是开它的那台 Mac 的时钟。
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

  /// 订阅库的变化，别的进程写下也收得到。
  /// 每条请求都带期限，没人领取、没人回执的到点也按 `latest(of:)` 推出的结果返回，不会一直等。
  /// 请求在等待期间被撤回、清理时抛 `CueStoreError.notFound`。
  public nonisolated func outcome(of request: DeliveryRequest) async throws -> DeliveryRequest {
    for try await current in observe({ try $0.latest(of: request) }) {
      guard let current else { throw CueStoreError.notFound }
      if !current.isOpen { return current }
    }
    throw CancellationError()
  }

  /// 发出的话已成了对话里的消息（之后请求被收走）就是已送达；撤回、清理了为 nil。
  public func latest(of request: DeliveryRequest) throws -> DeliveryRequest? {
    if var current = try deliveryRequest(request.id) {
      guard current.isOpen else { return current }
      let moment = Speech.Moment.always(at: timing.now())
      switch Speech.trip(current, at: moment) {
      case .unconfirmed:
        current.status = .known(.unconfirmed)
        current.reason = Speech.unconfirmedReason
      default:
        if let due = Speech.deadline(current) { expire(at: due) }
      }
      return current
    }
    guard try db.first("SELECT 1 FROM piMessages WHERE deliveryID = ?", [request.id], { _ in true }) != nil else { return nil }
    var arrived = request
    arrived.status = .known(.succeeded)
    return arrived
  }

  public func deliveryRequests(toSession sessionID: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND targetRef = ?", [sessionID],
      orderBy: "createdAt, rowid")
  }

  /// 明确未交出的失败请求才允许用于重发或移除；按当前存储状态判定，不信界面上旧的失败快照。
  public func withdrawFailedDelivery(_ id: UUID) throws -> Bool {
    try write { try removeFailedDelivery(id) }
  }

  func removeFailedDelivery(_ id: UUID) throws -> Bool {
    try db.run("DELETE FROM deliveryRequests WHERE id = ? AND status = '\(DeliveryStatus.failed.rawValue)'", [id])
    guard db.changes > 0 else { return false }
    try reopen(where: "setAsideBy = ?", [id])
    return true
  }

  /// 显式清理记录，不授权重投；重发与移除气泡走 withdrawDelivery / withdrawFailedDelivery。
  public func deleteDelivery(_ id: UUID) throws {
    try write {
      try db.run("DELETE FROM deliveryRequests WHERE id = ?", [id])
      try reopen(where: "setAsideBy = ?", [id])
    }
  }

  /// 撤回只在执行它的本机能与领取原子互斥；跨设备只允许从未交给同步发送者的请求。
  /// 已上传或正在上传的 pending 可能只是旧快照，删除成功也不能证明宿主尚未领取。这句收起的提问放回"等你"（同 `deleteDelivery`）。
  public func withdrawDelivery(_ id: UUID, locallyOn host: String? = nil) throws -> Bool {
    try write { try removeUnstartedDelivery(id, locallyOn: host) }
  }

  func removeUnstartedDelivery(_ id: UUID, locallyOn host: String?) throws -> Bool {
    try db.run(
      """
      DELETE FROM deliveryRequests WHERE id = ?1 AND status IN (\(DeliveryStatus.waitingSQL)) AND handledBy IS NULL
        AND (hostID = ?2 OR NOT EXISTS (
          SELECT 1 FROM syncRecords WHERE recordName = ?1 AND (sentModifiedAt IS NOT NULL OR pushedModifiedAt IS NOT NULL)))
      """, [id, host])
    guard db.changes > 0 else { return false }
    try reopen(where: "setAsideBy = ?", [id])
    return true
  }
}
