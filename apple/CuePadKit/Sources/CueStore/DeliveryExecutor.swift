import CueText
import Foundation
import os

extension CueStore {
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

  /// 写回结果：失败的原因随 `DeliveryOutcome.failed` 一起来，没有不带原因的失败。
  /// 只改还没有结果的（放弃的是待领取的、执行的是执行中的），不覆盖已经写下的结果。
  /// 任务的状态与正文都不因说话而变：发出的正文留在任务上，"发过没有"看投送请求。
  /// 你的作答成功了，同一个事务里往那个会话的对话写下你答了什么（`PiChatRole.answer`；Cue 替你答的不写，记在它那一轮的经过里）。
  fileprivate func finishDelivery(_ id: UUID, _ outcome: DeliveryOutcome, at completed: Date) throws {
    let (status, reason): (DeliveryStatus, ShownText?) =
      switch outcome {
      case .succeeded: (.succeeded, nil)
      case .failed(let reason), .transient(let reason): (.failed, reason)
      }
    try write {
      try db.run(
        """
        UPDATE deliveryRequests SET status = ?, failure = ?, completedAt = ?, modifiedAt = ?
        WHERE id = ? AND status IN (\(DeliveryStatus.openSQL))
        """, [status.rawValue, reason?.stored, completed, Date.stamp, id])
      guard db.changes > 0, status == .succeeded, let request = try find(DeliveryRequest.self, id), !request.isFromCue,
        let answer = request.answer, let session = request.target.ref
      else { return }
      // 排在会话文件里此刻最后一条之后（作答时 Agent 停着等你，接下来的都在它之后）；对话按 `at` 把它插到答的那一刻：
      // 你写下作答请求的时刻，不是这里执行完的时刻（离线答的、Mac 晚领取的，执行晚于答）
      let seq = try db.first("SELECT MAX(seq) FROM piMessages WHERE sessionID = ?", [session]) { $0.isNull(0) ? 0 : $0.int(0) } ?? 0
      _ = try insert(
        PiChatMessage(
          sessionID: session, entryID: "answer/\(id.uuidString.lowercased())", seq: seq, role: .answer, text: answer.value.said, at: request.createdAt,
          deliveryID: id, question: answer.question),
        ignoringExisting: true)
    }
  }

  fileprivate func failInterruptedDeliveries(host: String, at now: Date) throws {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests SET status = 'failed', failure = ?, completedAt = ?, modifiedAt = ?
        WHERE status = 'executing' AND handledBy = ?
        """, [ShownText("Mac 上的 CuePad 在执行过程中退出，为避免重复发送没有重试").stored, now, Date.stamp, host])
    }
  }

  /// 删除完成时间早于 `cutoff` 的请求；返回是否还剩已完成的（还剩就再排一轮）。
  /// 带着灵感或任务、已成功的开新会话请求在被认领前留着（会话记录可能晚到，认领靠它，见 `claimLaunchedCards`），
  /// 最多等到完成时间早于 `claimCutoff`（会话记录始终没到）；认领了、失败了、或之后又交给了别处（不会再被认领）就按保留期清理。
  /// 发出的话（`send`）不按保留期清：送到的等它成了对话里的消息时随之收走（`applyTranscript`），气泡才不会在进对话之前没了；
  /// 没能送达的留着等用户重发或移除（重发写成后移除它）。Cue 发起的请求失败了留着给 Cue 醒来时看（`cueChanges`）。
  /// 这几种都至多留到完成早于 `keptCutoff`。
  fileprivate func deleteCompletedDeliveries(before cutoff: Date, claimCutoff: Date, keptCutoff: Date) throws -> Bool {
    let done = "status IN ('succeeded', 'failed')"
    let kept = """
      completedAt >= ?3 AND (mode = '\(DeliveryMode.send.rawValue)' OR (status = 'failed' AND origin IS '\(DeliveryOrigin.cue.rawValue)'))
      """
    let awaitingClaim = """
      mode = 'start' AND status = 'succeeded' AND cardID IS NOT NULL AND completedAt >= ?2
        AND \(Self.latestHandoff("deliveryRequests")) AND \(Self.launchUnclaimed)
      """
    let arguments: [any SQLBindable] = [cutoff, claimCutoff, keptCutoff]
    return try write {
      try db.run(
        "DELETE FROM deliveryRequests WHERE \(done) AND completedAt < ?1 AND NOT (\(awaitingClaim)) AND NOT (\(kept))",
        arguments)
      return try db.first("SELECT 1 FROM deliveryRequests WHERE \(done) AND NOT (\(kept))", arguments) { _ in true } != nil
    }
  }
}

/// Mac 端的投送执行器：只领取发给本机（`hostID` 等于本机）的请求，一次一个、按创建顺序，经 `handler` 交给 App 层真正执行，
/// 把结果写回请求；完成的请求保留 `retention` 后清理（发出的话等它进对话、等认领的开新会话请求等认领，见 `deleteCompletedDeliveries`）。
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
  /// 创建后多久还没执行就放弃。
  package static let maxAge: Duration = .seconds(600)
  /// 完成的请求保留多久。
  package static let retention: Duration = .seconds(60)
  private let timing: Timing
  private let onIssue: @Sendable (any Error) -> Void
  private let onWritten: @Sendable (DeliveryRequest.ID) async -> Void
  private let handler: @Sendable (DeliveryRequest) async -> DeliveryOutcome
  private static let log = Logger(subsystem: AppIdentity.id, category: "delivery")
  private var watcher: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var processing = false
  private var rerun = false

  public init(
    store: CueStore, hostID: String,
    timing: Timing = .system, onIssue: @escaping @Sendable (any Error) -> Void,
    onWritten: @escaping @Sendable (DeliveryRequest.ID) async -> Void = { _ in },
    handler: @escaping @Sendable (DeliveryRequest) async -> DeliveryOutcome
  ) {
    self.store = store
    self.hostID = hostID
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
      if timing.now().timeIntervalSince(request.createdAt) > Self.maxAge.seconds {
        await finish(request, .failed(ShownText("请求创建后超过 \(Int(Self.maxAge.seconds)) 秒仍未执行，已放弃")))
        continue
      }
      if case .unknown(let raw) = request.mode {
        await finish(request, .failed(ShownText("这个版本的 CuePad 不认识发送方式「\(raw)」，没有执行（可能来自更新版本，请升级 Mac 上的 CuePad）")))
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
    let started = timing.now()
    var outcome = await handler(request)
    if case .transient = outcome, (try? await timing.sleep(Speech.retryDelay)) != nil {
      outcome = await handler(request)
    }
    let took = timing.now().timeIntervalSince(started)
    Self.log.info("执行投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public) 用时 \(took, format: .fixed(precision: 2)) 秒")
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

  /// 发出的话与 Cue 的失败请求最多留多久（与对话的保留期一样是 7 天）。
  private static let keptRetention: TimeInterval = 7 * 86_400

  private func scheduleCleanup() {
    guard cleanup == nil else { return }
    cleanup = Task { [timing] in
      guard (try? await timing.sleep(Self.retention)) != nil else { return }
      let remaining = await self.reporting { try await self.deleteExpired() }
      self.cleanupFinished(rescheduling: remaining ?? true)
    }
  }

  /// 清理一轮；返回是否还剩已完成的。
  private func deleteExpired() async throws -> Bool {
    let now = timing.now()
    return try await store.deleteCompletedDeliveries(
      before: now.addingTimeInterval(-Self.retention.seconds), claimCutoff: now.addingTimeInterval(-Self.maxAge.seconds),
      keptCutoff: now.addingTimeInterval(-Self.keptRetention))
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
