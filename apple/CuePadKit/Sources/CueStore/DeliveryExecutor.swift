import CueText
import Foundation

extension CueStore {
  /// 手机端：写一条投送请求，等 `host` 指定的那台 Mac 执行。必须指定：只有被指定的 Mac 会领取，
  /// 所以同一请求不会被多台 Mac 各执行一次。`host` 取自该目标 Pi 会话的 `PiSessionState.hostID`。
  @discardableResult
  public func requestDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode = .send, card: UUID? = nil,
    task: UUID? = nil
  ) throws -> DeliveryRequest {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    return try write {
      let now = Date.stamp
      let request = DeliveryRequest(
        id: UUID(), content: content, target: target, hostID: host, mode: .known(mode), cardID: card, taskID: task,
        status: .known(.pending), resultDetail: nil, handledBy: nil, createdAt: now, completedAt: nil, modifiedAt: now)
      try insert(request)
      try registerImages(in: content)
      return request
    }
  }

  /// 所有投送请求，最近的在前。
  public func deliveryRequests() throws -> [DeliveryRequest] {
    try select(DeliveryRequest.self, orderBy: "createdAt DESC, rowid DESC")
  }

  public func deliveryRequest(_ id: UUID) throws -> DeliveryRequest? { try find(DeliveryRequest.self, id) }

  public func deleteDelivery(_ id: UUID) throws {
    try write { try db.run("DELETE FROM deliveryRequests WHERE id = ?", [id]) }
  }

  // MARK: 执行器用

  fileprivate func pendingDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "status = 'pending' AND hostID = ?", [host],
      orderBy: "createdAt, rowid")
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

  fileprivate func finishDelivery(_ id: UUID, status: DeliveryStatus, detail: String?, at completed: Date) throws {
    try write {
      try db.run(
        "UPDATE deliveryRequests SET status = ?, resultDetail = ?, completedAt = ?, modifiedAt = ? WHERE id = ?",
        [status.rawValue, detail, completed, Date.stamp, id])
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

  /// 删除完成时间早于 `cutoff` 的请求；返回是否还剩已完成但未到期的。
  fileprivate func deleteCompletedDeliveries(before cutoff: Date) throws -> Bool {
    try write {
      try db.run(
        "DELETE FROM deliveryRequests WHERE status IN ('succeeded', 'failed') AND completedAt < ?", [cutoff])
      return try db.first("SELECT 1 FROM deliveryRequests WHERE status IN ('succeeded', 'failed')") { _ in true } != nil
    }
  }
}

/// Mac 端的投送执行器：只领取发给本机（`hostID` 等于本机）的请求，一次一个、按创建顺序，经 `handler` 交给 App 层真正执行，
/// 把结果写回请求；完成的请求保留 `retention` 后清理。
/// - 创建后超过 `maxAge` 还没执行的请求直接判失败（Mac 离线太久后不再突然发出旧内容）；
/// - 请求引用的图片还没同步到本机时先等着，图片到达（观察到附件变化）后再执行；
/// - 启动时，上次执行到一半的请求判失败且不重试（可能已经发出）；
/// - 读写 Store 失败交给 `onIssue`（请求停在原状态，手机那边会一直等，必须让人看到），下一次变化时再试。
public actor DeliveryExecutor {
  private let store: CueStore
  private let hostID: String
  private let maxAge: Duration
  private let retention: Duration
  private let timing: Timing
  private let onIssue: @Sendable (any Error) -> Void
  private let handler: @Sendable (DeliveryRequest) async -> DeliveryOutcome
  private var watcher: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var processing = false
  private var rerun = false

  public init(
    store: CueStore, hostID: String, maxAge: Duration = .seconds(600), retention: Duration = .seconds(60),
    timing: Timing = .system, onIssue: @escaping @Sendable (any Error) -> Void,
    handler: @escaping @Sendable (DeliveryRequest) async -> DeliveryOutcome
  ) {
    self.store = store
    self.hostID = hostID
    self.maxAge = maxAge
    self.retention = retention
    self.timing = timing
    self.onIssue = onIssue
    self.handler = handler
  }

  public func start() async throws {
    guard watcher == nil else { return }
    try await store.failInterruptedDeliveries(host: hostID, at: timing.now())
    _ = try await store.deleteCompletedDeliveries(before: timing.now().addingTimeInterval(-retention.seconds))
    watcher = Task { [store, onIssue] in
      // 附件也要观察：等图片的请求在图片到达时才能继续
      do {
        for try await _ in store.observe([.deliveryRequests, .attachments], { _ in () }) { await self.process() }
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
      if await reporting({ try await store.claimDelivery(request.id, host: hostID) }) == true { return request }
    }
    return nil
  }

  private func run(_ request: DeliveryRequest) async {
    await finish(request, await handler(request))
  }

  private func finish(_ request: DeliveryRequest, _ outcome: DeliveryOutcome) async {
    let (status, detail): (DeliveryStatus, String?) =
      switch outcome {
      case .succeeded: (.succeeded, nil)
      case .failed(let reason): (.failed, reason)
      }
    await reporting { try await store.finishDelivery(request.id, status: status, detail: detail, at: timing.now()) }
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

  private func scheduleCleanup() {
    guard cleanup == nil else { return }
    cleanup = Task { [timing, retention, store] in
      guard (try? await timing.sleep(retention)) != nil else { return }
      let remaining = await self.reporting {
        try await store.deleteCompletedDeliveries(before: timing.now().addingTimeInterval(-retention.seconds))
      }
      self.cleanupFinished(rescheduling: remaining ?? true)
    }
  }

  private func cleanupFinished(rescheduling: Bool) {
    cleanup = nil
    if rescheduling { scheduleCleanup() }
  }
}
