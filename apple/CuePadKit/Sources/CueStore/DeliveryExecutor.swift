import Foundation
import os

/// Mac 端的投送执行器：只领取发给本机的请求，一次一个、按创建顺序，经 `handler` 交给 App 层真正执行，把结果写回请求。完成的请求保留 `retention` 后清理，保留规则见 `deleteCompletedDeliveries`。
/// - 派发期限从服务器收下它起算（`DeliveryRequest.dispatchDeadline`）：到期还没领取的按失败写回，Mac 离线太久后不再突然发出旧内容；
/// - 缺前提时在旁边等，与派发期限赛跑，不占执行队列：引用的附件不在本机就取，现有会话没就绪就转准备（`preparing`）等它；取不来、到期都按失败写回；
/// - 每次领取只交给 handler 一次；任何执行后未知都留待正证据对账，不在领取内重试；
/// - 启动时只恢复上次请求的核对，不重派、不续期；
/// - 读写 Store 失败交给 `onIssue`；
/// - 写回结果后调用一次 `onWritten`（App 用它立即上传这一条，排在其余待推送前面）；执行超过 `claimGrace` 的，领取那一版先传一次：
///   发起的设备据领取知道 Mac 接手了，但不能据此断言已交给 Agent。多数执行几十毫秒就完，只传结果那一版：
///   领取那一版在路上时结果得等它回来才能传（同一条记录一次只一版在路上），回执要多等一个来回。
public actor DeliveryExecutor {
  let store: CueStore
  let hostID: String
  package static let retention: Duration = .seconds(60)
  /// 执行多久还没完就先把领取传出去。说给在线会话的话交给桥几十毫秒就有结果，留足机器忙时的余量；远短于 `Speech.receiptLimit`。
  package static let claimGrace: Duration = .milliseconds(500)
  let timing: Timing
  private let onIssue: @Sendable (any Error) -> Void
  private let onWritten: @Sendable (DeliveryRequest.ID) async -> Void
  private let recover: @Sendable (DeliveryRequest) async -> DeliveryOutcome
  private let preparation: @Sendable (DeliveryRequest) async -> DeliveryAdmission
  var waiting = Slots<DeliveryRequest.ID>()
  private let handler: @Sendable (DeliveryRequest, DeliveryAdmission.Access) async -> DeliveryOutcome
  /// 把一个附件取到本机（App 给的 `AppServices.fetchFile`）：执行器等附件文件只在这里；缺省是这台取不来
  let fetchFile: @Sendable (String) async throws -> Void
  private var uploads = Slots<UUID>()
  private var confirmations = Slots<DeliveryRequest.ID>()
  var fetching = Slots<DeliveryRequest.ID>()
  private static let log = Logger(subsystem: AppIdentity.id, category: "delivery")
  var started = false
  /// 各只有一个的后台任务：`claimUpload` 是正在执行的那一条到 `claimGrace` 才传领取（结果先写下就不传）。
  /// `expiry` 是期限监视：到期没领取的按失败写回，不经执行队列——上一条 handler 不响应取消、队列停在等它时（一次一个），后面的话照样到期收尾。
  enum Role { case starting, watcher, expiry, cleanup, runner, claimUpload }
  var roles = Slots<Role>()
  /// 上一次 `stop` 等本轮任务收尾的那一段：`start` 等它过去才开新一轮，旧一轮的任务不会与新一轮同时在跑。
  private var draining: Task<Void, Never>?
  private var rerun = false
  private var handling: Task<DeliveryOutcome, Never>?
  var cleanupWake: Date?
  private var startFailure: (any Error)?

  public init(
    store: CueStore, hostID: String,
    timing: Timing = .system, onIssue: @escaping @Sendable (any Error) -> Void,
    onWritten: @escaping @Sendable (DeliveryRequest.ID) async -> Void = { _ in },
    fetchFile: @escaping @Sendable (String) async throws -> Void = { _ in throw CueStoreError.notFound },
    recover: @escaping @Sendable (DeliveryRequest) async -> DeliveryOutcome = { _ in .unconfirmed(DeliveryRequest.interruptedReason) },
    preparation: @escaping @Sendable (DeliveryRequest) async -> DeliveryAdmission = { _ in .ready(.resumable) },
    handler: @escaping @Sendable (DeliveryRequest, DeliveryAdmission.Access) async -> DeliveryOutcome
  ) {
    self.store = store
    self.hostID = hostID
    self.timing = timing
    self.onIssue = onIssue
    self.onWritten = onWritten
    self.preparation = preparation
    self.handler = handler
    self.recover = recover
    self.fetchFile = fetchFile
  }

  /// 起停只有三态：停着（`started` 假、`draining` 已过）→ `start` → 在跑（`started` 真，先跑启动恢复）→ `stop` → 停止中（`started` 假、等 `draining`）→ 停着。
  /// 停止中调用 `start` 等它停完再开新一轮。一轮只等自己的回调：上一轮丢下的（不响应取消的 handler）不等，它的请求由新一轮的启动恢复按未知对账。
  /// 在已取消的任务里调用抛 `CancellationError`、什么都不起：退出收尾取消了启动任务、停过执行器后，迟到的启动不会再起一轮没人停的。
  /// 启动恢复读写失败时停回停着并抛出。
  public func start() async throws {
    await draining?.value
    try Task.checkCancellation()
    guard !started else { return }
    started = true
    // 恢复段登记为 stop 能取消并收齐的任务：停止再启动时，旧一轮的恢复已被取消，不会与新一轮同时跑、也不会覆盖新一轮的监听
    let boot = Owned.spawn { id in await self.boot() }
    roles.put(.starting, boot)
    await boot.task.value
    roles.release(.starting, boot.id)
    if let failure = startFailure {
      startFailure = nil
      await stop()
      throw failure
    }
  }

  private func boot() async {
    do {
      try await store.releaseDeliveryReservations(for: hostID)
      for id in try await store.abandonPreparedDeliveries(for: hostID) { notifyWritten(id) }
      for request in try await store.unsettledDeliveries(for: hostID) {
        guard started, !Task.isCancelled else { return }
        guard let outcome = await perform({ [recover] in await recover(request) }) else { return }
        await finish(request, outcome, resuming: true)
      }
      guard started, !Task.isCancelled else { return }
      let next = try await deleteExpired()
      guard started, !Task.isCancelled else { return }
      if let next { scheduleCleanup(at: next) }
      roles.put(.expiry, .spawn { [store, hostID, onIssue] _ in
        do {
          for try await expired in store.observe({ try $0.expiredUnclaimedDeliveries(for: hostID) }) { await self.expire(expired) }
        } catch {
          if !Task.isCancelled { onIssue(error) }
        }
      })
      roles.put(.watcher, .spawn { [store, hostID, onIssue] _ in
        do {
          for try await _ in store.observe({ try $0.pendingDeliveries(for: hostID).map(\.id) }) {
            // 锚定在这里、不在执行队列里：上一条 handler 卡住、队列停着时，新写给自己的请求照样有期限，期限监视照样收尾
            await self.reporting { try await store.actionableDeliveries(for: hostID) }
            self.enqueue()
          }
        } catch {
          if !Task.isCancelled { onIssue(error) }
        }
      })
    } catch {
      if !Task.isCancelled { startFailure = error }
    }
  }

  public func stop() async {
    started = false
    let tasks = roles.cancelAll() + fetching.cancelAll() + waiting.cancelAll() + confirmations.cancelAll() + uploads.cancelAll()
    handling = nil
    let previous = draining
    let drain = Task {
      await previous?.value
      for task in tasks { await task.value }
    }
    draining = drain
    await drain.value
  }

  func enqueue() {
    guard started, !Task.isCancelled else { return }
    if roles.has(.runner) { rerun = true; return }
    roles.put(.runner, .spawn { id in await self.process(id) })
  }

  private func process(_ id: UUID) async {
    defer { roles.release(.runner, id) }
    repeat {
      rerun = false
      while started, !Task.isCancelled, await settleHandler(), let next = await nextActionable() { await run(next) }
    } while rerun && !Task.isCancelled
  }

  /// 执行 handler 或启动对账的 recover：取消时调用方不等它（`abandonable`），但回调留在 `handling` 里，本轮下一次执行前先等它结束（`settleHandler`），
  /// 所以同一轮里不会与还没结束的上一个回调同时执行；`stop` 丢下它，不拖住下一轮。被取消返回 nil。
  private func perform(until deadline: Date? = nil, _ operation: @escaping @Sendable () async -> DeliveryOutcome) async -> DeliveryOutcome? {
    let work = Task { await operation() }
    handling = work
    let outcome = try? await withThrowingTaskGroup(of: DeliveryOutcome.self) { group in
      group.addTask { try await abandonable { await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() } } }
      if let deadline {
        group.addTask { [timing] in
          try await timing.sleepUntil(deadline)
          work.cancel()
          return .unconfirmed(Speech.unconfirmedReason)
        }
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    if outcome != nil, !work.isCancelled { handling = nil }
    return outcome
  }

  private func settleHandler() async -> Bool {
    guard let prior = handling else { return true }
    guard (try? await abandonable({ _ = await prior.value })) != nil else { return false }
    handling = nil
    return true
  }

  private func nextActionable() async -> Dispatch? {
    if let abandoned = await reporting({ try await store.abandonPreparedDeliveries(for: hostID) }) {
      for id in abandoned { notifyWritten(id) }
    }
    guard let candidates = await reporting({ try await store.actionableDeliveries(for: hostID) }) else { return nil }
    for request in candidates {
      if waiting.has(request.id) || fetching.has(request.id) { continue }
      if isExpired(request) {
        await finish(request, .failed(request.expiry))
        continue
      }
      if case .unknown(let raw) = request.mode {
        await finish(request, .failed(ShownText("这个版本的 CuePad 不认识发送方式「\(raw)」，没有执行（可能来自更新版本，请升级 Mac 上的 CuePad）")))
        continue
      }
      let missing = request.attachmentKeys.filter { store.files.fileURL(for: $0) == nil }
      if !missing.isEmpty {
        fetch(missing, for: request)
        continue
      }
      let access: DeliveryAdmission.Access
      switch await preparation(request) {
      case .waiting(let pending):
        await prepare(request, pending)
        continue
      case .ready(let allowed): access = allowed
      }
      guard started, !Task.isCancelled else { return nil }
      let reserved = await reporting {
        switch access {
        case .existingOnly: return try await store.reserveDeliveryTarget(request.id, host: hostID)
        case .resumable: return try await store.claimDelivery(request.id, host: hostID, until: timing.now().addingTimeInterval(DeliveryRequest.phaseLimit))
        }
      }
      if let claimed = reserved, let claimed {
        let age = timing.now().timeIntervalSince(request.createdAt)
        Self.log.info("领取投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public)，创建后 \(age, format: .fixed(precision: 1)) 秒")
        return Dispatch(request: claimed, access: access)
      }
      // 领取与到期在同一刻：领不到了，当场写回失败，不等下一次有别的请求来叫醒
      if isExpired(request) { await finish(request, .failed(request.expiry)) }
    }
    return nil
  }

  /// 期限监视读到的到期请求按失败写回；在旁边取附件、等会话就绪的由那个任务自己到期写回（带着在等什么），这里不抢。
  private func expire(_ requests: [DeliveryRequest]) async {
    for request in requests where !fetching.has(request.id) && !waiting.has(request.id) {
      await finish(request, .failed(request.expiry))
    }
  }

  func isExpired(_ request: DeliveryRequest) -> Bool { request.dispatchDeadline.map { timing.now() >= $0 } ?? false }

  private struct Dispatch {
    let request: DeliveryRequest
    let access: DeliveryAdmission.Access
  }

  private func run(_ dispatch: Dispatch) async {
    guard started, !Task.isCancelled else { return }
    var request = dispatch.request
    if request.status == .known(.preparing) {
      if case .waiting(let pending) = await preparation(request) {
        await prepare(request, pending)
        return
      }
      guard started, !Task.isCancelled else { return }
      guard let begun = await reporting({ try await store.beginDelivery(request.id, on: hostID, until: timing.now().addingTimeInterval(DeliveryRequest.phaseLimit)) }),
            let begun else {
        await reporting { try await store.releaseDeliveryReservations(for: hostID, only: request.id) }
        return
      }
      request = begun
    }
    guard started, !Task.isCancelled else { return }
    roles.put(.claimUpload, .spawn { [timing] _ in
      guard (try? await timing.sleep(Self.claimGrace)) != nil else { return }
      self.notifyWritten(request.id)
    })
    let began = timing.now()
    // 与取消隔开：handler 不响应取消时 stop 不被它拖住，它留在脱离的任务里自己收尾，结果丢弃（请求已领取，重启时按未知对账）
    let running = request
    let outcome = await perform(until: request.deadlineAt) { [handler] in await handler(running, dispatch.access) }
    roles.cancel(.claimUpload)
    guard let outcome else { return }
    let took = timing.now().timeIntervalSince(began)
    Self.log.info("执行投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public) 用时 \(took, format: .fixed(precision: 2)) 秒")
    await finish(request, outcome)
  }

  func finish(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, resuming: Bool = false) async {
    guard started, !Task.isCancelled else { return }
    let continuing: Bool = if case .confirming = outcome { resuming } else { false }
    if !continuing {
      if let changed = await reporting({ try await store.finishDelivery(request, outcome, at: timing.now()) }) {
        let confirmed: Bool = if case .succeeded = outcome { true } else { false }
        if changed || confirmed { notifyWritten(request.id) }
      }
    }
    if case .confirming(let verify) = outcome,
      let stored = await reporting({ try await store.deliveryRequest(request.id) }), let stored,
      stored.status != .known(.succeeded), started, !Task.isCancelled {
      confirmations.put(stored.id, .spawn { id in
        guard let result = try? await abandonable({ await verify(stored) }) else { return }
        await self.finish(stored, result)
        self.confirmations.release(stored.id, id)
      })
    }
    if started, !Task.isCancelled { scheduleCleanup() }
  }

  /// 上传回执也不占执行通道；同一条的版本顺序由同步发送器负责，这里只持有可取消任务。
  func notifyWritten(_ id: UUID) {
    guard started, !Task.isCancelled else { return }
    let token = UUID()
    uploads.put(token, .spawn { [onWritten] owner in
      guard !Task.isCancelled else { return }
      guard (try? await abandonable({ await onWritten(id) })) != nil else { return }
      self.uploads.release(token, owner)
    })
  }

  /// 执行 Store 读写；失败交给 `onIssue` 并返回 nil。`stop()` 之后（所在任务已取消）的失败不再上报。
  @discardableResult
  func reporting<T>(_ operation: () async throws -> T) async -> T? {
    do { return try await operation() } catch {
      if !Task.isCancelled { onIssue(error) }
      return nil
    }
  }
}
