import CueText
import Foundation
import os

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
  /// 这件事里没人再用的会话随之结束（`endUnusedSessions`）。
  func insertDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode, card: UUID? = nil, cue: Bool
  ) throws -> DeliveryRequest {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    let now = Date.stamp
    let request = DeliveryRequest(
      id: UUID(), content: content, target: target, hostID: host, mode: .known(mode), cardID: card,
      status: .known(.pending), resultDetail: nil, handledBy: nil, createdAt: now, completedAt: nil, modifiedAt: now,
      resultReceivedAt: nil, origin: cue ? .known(.cue) : nil)
    try insert(request)
    try registerImages(in: content)
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

  /// 正文就是方式名的控制类请求（结束、停止）：同一会话同一种方式在路上只有一条。必须在写事务内调用。
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
  static let launchUnclaimed = """
    NOT EXISTS (SELECT 1 FROM piSessionStates s
      WHERE s.launchToken = CASE WHEN json_valid(deliveryRequests.content) THEN json_extract(deliveryRequests.content, '$.token') END)
    """

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
      FROM deliveryRequests r JOIN piSessionStates s
        ON s.launchToken = CASE WHEN json_valid(r.content) THEN json_extract(r.content, '$.token') END
      WHERE r.cardID = cards.id AND r.mode = 'start'
        AND r.createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = cards.id)
        AND cards.piSessionID IS NOT s.sessionID
      """, [Date.stamp])
  }

  /// 请 `host` 那台 Mac 给项目绑定文件夹（`PiBind.folder` 为 nil 是解除）：手机没有完整路径，由 Mac 解析并写本机的目录绑定。
  /// `title` 是项目名（给人看的目标名）。
  public func requestBind(_ bind: PiBind, title: String, on host: String) throws -> DeliveryRequest {
    try requestDelivery(bind.stored, to: SendTarget(kind: .mac, name: title, ref: nil), on: host, mode: .bind)
  }

  /// 连接测试：请 `host` 那台 Mac 收到就回。目标写成那台 Mac 上的 CuePad（执行器不看目标）。
  public func requestPing(on host: String) throws -> DeliveryRequest {
    try requestDelivery("ping", to: SendTarget(kind: .mac, name: "CuePad", ref: nil), on: host, mode: .ping)
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

  /// 等到投送请求有结果（已送达或没能送达）：订阅库的变化，别的进程（执行它的 Mac 上的 App、同步拉回的结果）写下也收得到。
  /// 请求在等待期间被删掉时抛 `CueStoreError.notFound`。
  public nonisolated func outcome(of request: UUID) async throws -> DeliveryRequest {
    for try await current in observe({ try $0.deliveryRequest(request) }) {
      guard let current else { throw CueStoreError.notFound }
      if !current.isOpen { return current }
    }
    throw CancellationError()
  }

  /// 发给一个 Pi 会话（按 Pi 的会话 id）的所有投送请求，先发的在前。
  public func deliveryRequests(toSession sessionID: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND targetRef = ?", [sessionID],
      orderBy: "createdAt, rowid")
  }

  public func deleteDelivery(_ id: UUID) throws {
    try write { try db.run("DELETE FROM deliveryRequests WHERE id = ?", [id]) }
  }

  /// 撤回一条还没被 Mac 领取的请求（`isWithdrawable`）；返回是否撤回了。与领取同一个条件（status = 'pending'），
  /// 所以撤回与领取只有一个能成：已领取的（交给了 Pi）撤不回。
  public func withdrawDelivery(_ id: UUID) throws -> Bool {
    try write {
      try db.run("DELETE FROM deliveryRequests WHERE id = ? AND status = 'pending'", [id])
      return db.changes > 0
    }
  }

  /// 把还没被领取的"等它做完再说"改成"马上说"；返回是否改成了（同 `withdrawDelivery`，已领取的改不了）。
  public func promoteDelivery(_ id: UUID) throws -> Bool {
    try write {
      try db.run(
        "UPDATE deliveryRequests SET mode = ?, modifiedAt = ? WHERE id = ? AND status = 'pending' AND mode = ?",
        [DeliveryMode.steer.rawValue, Date.stamp, id, DeliveryMode.followUp.rawValue])
      return db.changes > 0
    }
  }

  // MARK: 执行器用

  fileprivate func pendingDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "status = 'pending' AND hostID = ?", [host],
      orderBy: "createdAt, rowid")
  }

  /// 执行器要醒来的理由：有新的请求等着，或有附件到达（等图片的请求这时才能继续）。
  fileprivate func executorQueue(for host: String) throws -> DeliveryQueue {
    DeliveryQueue(
      pending: try pendingDeliveries(for: host).map(\.id), attachments: try db.first("SELECT count(*) FROM attachments") { Int($0.int(0)) } ?? 0)
  }

  /// 领取：只有仍是 pending 的请求能被领取，同一请求不会被执行两次。
  fileprivate func claimDelivery(_ id: UUID, host: String) throws -> Bool {
    try write {
      try db.run(
        "UPDATE deliveryRequests SET status = 'executing', handledBy = ?, modifiedAt = ? WHERE id = ? AND status = 'pending'",
        [host, Date.stamp, id])
      return db.changes > 0
    }
  }

  /// 交出去之后才知道没送到：`host` 这台 Mac 受理了、Pi 会话却在读到这句之前关掉了（扩展在告别里报出：没来得及交给 Pi 的，或退出时还排在 Pi 队列里的），改记为失败，
  /// 走"没能送达 + 重发"。执行到一半的也算（告别可能先于执行器写回结果，写回不覆盖已有的结果，不会把它改回成功）。返回改了的。
  public func failAcceptedDeliveries(_ ids: [UUID], host: String, reason: String) throws -> [UUID] {
    try write {
      let now = Date.stamp
      return try ids.filter { id in
        try db.run(
          """
          UPDATE deliveryRequests SET status = 'failed', resultDetail = ?, completedAt = ?, modifiedAt = ?
          WHERE id = ? AND handledBy = ? AND status IN ('executing', 'succeeded')
          """, [reason, now, now, id, host])
        return db.changes > 0
      }
    }
  }

  /// 写回结果：失败的原因随 `DeliveryOutcome.failed` 一起来，没有不带原因的失败；Agent 收下的话把方式改写成它实际收下的（`accepted`）。
  /// 只改还没有结果的（放弃的是待领取的、执行的是执行中的），不覆盖已经写下的结果（见 `failAcceptedDeliveries`）。
  /// 任务的状态与正文都不因说话而变：发出的正文留在任务上，"发过没有"看投送请求。
  /// 你的作答成功了，同一个事务里往那个会话的对话写下你答了什么（`PiChatRole.answer`；Cue 替你答的不写，记在它那一轮的经过里）。
  fileprivate func finishDelivery(_ id: UUID, _ outcome: DeliveryOutcome, at completed: Date) throws {
    let (status, detail, mode): (DeliveryStatus, String?, DeliveryMode?) =
      switch outcome {
      case .succeeded: (.succeeded, nil, nil)
      case .accepted(let mode): (.succeeded, nil, mode)
      case .failed(let reason), .transient(let reason): (.failed, reason, nil)
      }
    try write {
      try db.run(
        """
        UPDATE deliveryRequests SET status = ?, resultDetail = ?, mode = COALESCE(?, mode), completedAt = ?, modifiedAt = ?
        WHERE id = ? AND status IN (\(DeliveryStatus.openSQL))
        """, [status.rawValue, detail, mode?.rawValue, completed, Date.stamp, id])
      guard db.changes > 0, status == .succeeded, let request = try find(DeliveryRequest.self, id), !request.isFromCue,
        let answer = request.answer, let session = request.target.ref
      else { return }
      // 排在会话文件里此刻最后一条之后（作答时 Agent 停着等你，接下来的都在它之后）；对话按 `at` 把它插到答的那一刻
      let seq = try db.first("SELECT MAX(seq) FROM piMessages WHERE sessionID = ?", [session]) { $0.isNull(0) ? 0 : $0.int(0) } ?? 0
      _ = try insert(
        PiChatMessage(
          sessionID: session, entryID: "answer/\(id.uuidString.lowercased())", seq: seq, role: .answer, text: answer.value.label, at: completed,
          deliveryID: id, question: answer.question),
        ignoringExisting: true)
    }
  }

  fileprivate func failInterruptedDeliveries(host: String, at now: Date) throws {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests SET status = 'failed', resultDetail = ?, completedAt = ?, modifiedAt = ?
        WHERE status = 'executing' AND handledBy = ?
        """, ["Mac 上的 CuePad 在执行过程中退出，为避免重复发送没有重试", now, Date.stamp, host])
    }
  }

  /// 删除完成时间早于 `cutoff` 的请求；返回是否还剩已完成的（还剩就再排一轮）。
  /// 带着灵感或任务、已成功的开新会话请求在被认领前留着（会话记录可能晚到，认领靠它，见 `claimLaunchedCards`），
  /// 最多等到完成时间早于 `claimCutoff`（会话记录始终没到）；认领了、失败了、或之后又交给了别处（不会再被认领）就按保留期清理。
  /// 排在 Agent 队列里的话（收下的方式是 steer / followUp）在被读到（对话里出现 `deliveryID` 等于它的消息）前、会话还忙着时留着：
  /// 界面据它显示排队的话，删早了话会在被读到前消失；会话停下后队列要么已读完、要么随进程丢了（告别里报没送到），下一轮就带走。
  /// 留着的都算"还剩"：清理一轮轮排下去，认领、读到或会话停下后的那一轮就带走它。
  /// 没能送达的话（说话的几种方式）在对话里留着等用户重发或移除（重发写成后移除它），Cue 发起的请求失败了留着给 Cue 醒来时看（`cueChanges`），
  /// 两者都只在完成早于 `undeliveredCutoff` 时清理；排队的话也最多留到这时。
  fileprivate func deleteCompletedDeliveries(before cutoff: Date, claimCutoff: Date, undeliveredCutoff: Date) throws -> Bool {
    let done = "status IN ('succeeded', 'failed')"
    let undelivered = """
      status = 'failed' AND (mode IN (\(sqlList(DeliveryMode.talk))) OR origin IS '\(DeliveryOrigin.cue.rawValue)') AND completedAt >= ?3
      """
    let awaitingClaim = """
      mode = 'start' AND status = 'succeeded' AND cardID IS NOT NULL AND completedAt >= ?2
        AND createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = deliveryRequests.cardID)
        AND \(Self.launchUnclaimed)
      """
    let queued = """
      status = 'succeeded' AND mode IN (\(sqlList([DeliveryMode.steer, .followUp]))) AND completedAt >= ?3
        AND NOT EXISTS (SELECT 1 FROM piMessages m WHERE m.sessionID = deliveryRequests.targetRef AND m.deliveryID = deliveryRequests.id)
        AND EXISTS (SELECT 1 FROM piSessionStates s WHERE s.sessionID = deliveryRequests.targetRef AND s.state IN (\(PiWorkState.pendingWorkSQL)))
      """
    let arguments: [any SQLBindable] = [cutoff, claimCutoff, undeliveredCutoff]
    return try write {
      try db.run(
        "DELETE FROM deliveryRequests WHERE \(done) AND completedAt < ?1 AND NOT (\(awaitingClaim)) AND NOT (\(undelivered)) AND NOT (\(queued))",
        arguments)
      return try db.first("SELECT 1 FROM deliveryRequests WHERE \(done) AND NOT (\(undelivered))", arguments) { _ in true } != nil
    }
  }

}

/// Mac 端的投送执行器：只领取发给本机（`hostID` 等于本机）的请求，一次一个、按创建顺序，经 `handler` 交给 App 层真正执行，
/// 把结果写回请求；完成的请求保留 `retention` 后清理（等认领的开新会话请求最多留到 `maxAge`，见 `deleteCompletedDeliveries`）。
/// - 创建后超过 `maxAge` 还没执行的请求直接判失败（Mac 离线太久后不再突然发出旧内容）；
/// - 请求引用的图片还没同步到本机时先等着，图片到达（观察到附件变化）后再执行；
/// - 暂时没成的（`DeliveryOutcome.transient`）重试一次，再不成按失败写回；
/// - 启动时，上次执行到一半的请求判失败且不重试（可能已经发出）；
/// - 读写 Store 失败交给 `onIssue`（请求停在原状态，手机那边会一直等，必须让人看到），下一次变化时再试；
/// - 领取与写回结果后各调用一次 `onWritten`（App 用它立即上传这一条，排在其余待推送前面）：发起的设备据领取知道 Mac 接手了，
///   执行得久的（唤醒已结束的会话）不会被它报成超时没送到。领取的那次不等上传完就开始执行。
public actor DeliveryExecutor {
  private let store: CueStore
  private let hostID: String
  private let maxAge: Duration
  private let retention: Duration
  private let timing: Timing
  private let onIssue: @Sendable (any Error) -> Void
  private let onWritten: @Sendable (DeliveryRequest.ID) async -> Void
  private let handler: @Sendable (DeliveryRequest) async -> DeliveryOutcome
  private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "delivery")
  private var watcher: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var processing = false
  private var rerun = false

  public init(
    store: CueStore, hostID: String, maxAge: Duration = .seconds(600), retention: Duration = .seconds(60),
    timing: Timing = .system, onIssue: @escaping @Sendable (any Error) -> Void,
    onWritten: @escaping @Sendable (DeliveryRequest.ID) async -> Void = { _ in },
    handler: @escaping @Sendable (DeliveryRequest) async -> DeliveryOutcome
  ) {
    self.store = store
    self.hostID = hostID
    self.maxAge = maxAge
    self.retention = retention
    self.timing = timing
    self.onIssue = onIssue
    self.onWritten = onWritten
    self.handler = handler
  }

  public func start() async throws {
    guard watcher == nil else { return }
    try await store.failInterruptedDeliveries(host: hostID, at: timing.now())
    if try await deleteExpired() { scheduleCleanup() }
    watcher = Task { [store, hostID, onIssue] in
      do {
        for try await _ in store.observe({ try $0.executorQueue(for: hostID) }) { await self.process() }
      } catch {
        onIssue(error)
      }
    }
  }

  public func stop() {
    watcher?.cancel()
    watcher = nil
    cleanup?.cancel()
    cleanup = nil
  }

  private func process() async {
    if processing {
      rerun = true
      return
    }
    processing = true
    defer { processing = false }
    repeat {
      rerun = false
      while !Task.isCancelled, let next = await nextActionable() { await run(next) }
    } while rerun && !Task.isCancelled
  }

  private func nextActionable() async -> DeliveryRequest? {
    guard let candidates = await reporting({ try await store.pendingDeliveries(for: hostID) }) else { return nil }
    for request in candidates {
      if timing.now().timeIntervalSince(request.createdAt) > maxAge.seconds {
        await finish(request, .failed("请求创建后超过 \(Int(maxAge.seconds)) 秒仍未执行，已放弃"))
        continue
      }
      if case .unknown(let raw) = request.mode {
        await finish(request, .failed("这个版本的 CuePad 不认识发送方式「\(raw)」，没有执行（可能来自更新版本，请升级 Mac 上的 CuePad）"))
        continue
      }
      if hasMissingImages(request) { continue }
      if await reporting({ try await store.claimDelivery(request.id, host: hostID) }) == true {
        let age = timing.now().timeIntervalSince(request.createdAt)
        Self.log.info("领取投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public)，创建后 \(age, format: .fixed(precision: 1)) 秒")
        Task { [onWritten] in await onWritten(request.id) }
        return request
      }
    }
    return nil
  }

  /// 执行一条；暂时没成的隔 `Speech.retryDelay` 再执行一次（一条条按先后执行，等的这一下会拖住后面的请求，所以只重试一次）。
  private func run(_ request: DeliveryRequest) async {
    var outcome = await handler(request)
    if case .transient = outcome, (try? await timing.sleep(Speech.retryDelay)) != nil {
      outcome = await handler(request)
    }
    await finish(request, outcome)
  }

  private func finish(_ request: DeliveryRequest, _ outcome: DeliveryOutcome) async {
    if await reporting({ try await store.finishDelivery(request.id, outcome, at: timing.now()) }) != nil {
      await onWritten(request.id)
    }
    scheduleCleanup()
  }

  /// 执行 Store 读写；失败交给 `onIssue` 并返回 nil。`stop()` 之后（所在任务已取消）的失败不再上报。
  @discardableResult
  private func reporting<T>(_ operation: () async throws -> T) async -> T? {
    do { return try await operation() } catch {
      if !Task.isCancelled { onIssue(error) }
      return nil
    }
  }

  private func hasMissingImages(_ request: DeliveryRequest) -> Bool {
    CueFormat.imageHashes(in: request.content).contains { store.files.fileURL(for: $0) == nil }
  }

  /// 没能送达的话与 Cue 的失败请求最多留多久（与对话的保留期一样是 7 天）。
  private static let undeliveredRetention: TimeInterval = 7 * 86_400

  private func scheduleCleanup() {
    guard cleanup == nil else { return }
    cleanup = Task { [timing, retention] in
      guard (try? await timing.sleep(retention)) != nil else { return }
      let remaining = await self.reporting { try await self.deleteExpired() }
      self.cleanupFinished(rescheduling: remaining ?? true)
    }
  }

  /// 清理一轮；返回是否还剩已完成的。
  private func deleteExpired() async throws -> Bool {
    let now = timing.now()
    return try await store.deleteCompletedDeliveries(
      before: now.addingTimeInterval(-retention.seconds), claimCutoff: now.addingTimeInterval(-maxAge.seconds),
      undeliveredCutoff: now.addingTimeInterval(-Self.undeliveredRetention))
  }

  private func cleanupFinished(rescheduling: Bool) {
    cleanup = nil
    if rescheduling { scheduleCleanup() }
  }
}

/// 执行器看的队列状态（`CueStore.executorQueue`）：等执行的请求，与附件记录数。
struct DeliveryQueue: Equatable, Sendable {
  var pending: [UUID]
  var attachments: Int
}
