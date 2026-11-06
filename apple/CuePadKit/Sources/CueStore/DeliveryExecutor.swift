import Foundation
import os

/// Mac 端的投送执行器：只领取发给本机（`hostID` 等于本机）的请求，一次一个、按创建顺序，经 `handler` 交给 App 层真正执行，
/// 把结果写回请求；完成的请求保留 `retention` 后清理（发出的话等它进对话、等认领的开新会话请求等认领，见 `deleteCompletedDeliveries`）。
/// - 服务器收下后超过 `maxAge` 还没执行的请求直接判失败（Mac 离线太久后不再突然发出旧内容）。从服务器收下算、不从写下算：
///   在发出的设备上等着的那段（断网、要更新）你看得到它在等、撤得回，传上来就照常执行，同对 Cue 说的话；本机写的从写下算；
/// - 请求引用的附件不在本机时先在旁边取（`fetchFile`，一条请求一个任务），取齐才进队执行：等文件不占执行队列，
///   后面发给别的会话、对 Cue 说的话照常先执行；取不来按失败写回；准备与执行分别以 maxAge 为安全上限；
/// - 每次领取只交给 handler 一次；任何执行后未知都留待正证据对账，不在领取内重试；
/// - 启动时只恢复上次请求的核对，不重派、不续期；确认任务独立于执行通道，由 stop 取消并收齐；
/// - 读写 Store 失败交给 `onIssue`；持久阶段的期限仍使发送方有界收敛；
/// - 写回结果后调用一次 `onWritten`（App 用它立即上传这一条，排在其余待推送前面）；执行超过 `claimGrace` 的，领取那一版先传一次：
///   发起的设备据领取知道 Mac 接手了，但不能据此断言已交给 Agent。多数执行几十毫秒就完，只传结果那一版：
///   领取那一版在路上时结果得等它回来才能传（同一条记录一次只一版在路上），回执要多等一个来回。
public actor DeliveryExecutor {
  private let store: CueStore
  private let hostID: String
  /// 服务器收下后多久还没执行就放弃。
  package static let maxAge: Duration = .seconds(600)
  /// 完成的请求保留多久。
  package static let retention: Duration = .seconds(60)
  /// 执行多久还没完就先把领取传出去。说给在线会话的话交给桥几十毫秒就有结果，留足机器忙时的余量；远短于 `Speech.receiptLimit`。
  package static let claimGrace: Duration = .milliseconds(500)
  private let timing: Timing
  private let onIssue: @Sendable (any Error) -> Void
  private let onWritten: @Sendable (DeliveryRequest.ID) async -> Void
  private let recover: @Sendable (DeliveryRequest) async -> DeliveryOutcome
  private let preparation: @Sendable (DeliveryRequest) async -> DeliveryAdmission
  private var waiting = Slots<DeliveryRequest.ID>()
  private let handler: @Sendable (DeliveryRequest, DeliveryAdmission.Access) async -> DeliveryOutcome
  /// 把一个附件取到本机（App 给的 `AppServices.fetchFile`）：执行器等附件文件只在这里；缺省是这台取不来
  private let fetchFile: @Sendable (String) async throws -> Void
  private var uploads = Slots<UUID>()
  private var confirmations = Slots<DeliveryRequest.ID>()
  /// 在旁边取附件的请求
  private var fetching = Slots<DeliveryRequest.ID>()
  private static let log = Logger(subsystem: AppIdentity.id, category: "delivery")
  private var started = false
  /// 各只有一个的后台任务：`claimUpload` 是正在执行的那一条到 `claimGrace` 才传领取（结果先写下就不传）。
  private enum Role { case watcher, cleanup, runner, claimUpload }
  private var roles = Slots<Role>()
  /// 上一次 `stop` 等旧任务收尾的那一段：`start` 等它过去才开新一轮，旧 handler 不会与新循环同时在跑。
  private var draining: Task<Void, Never>?
  private var rerun = false
  private var cleanupWake: Date?

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

  public func start() async throws {
    await draining?.value
    guard !started else { return }
    started = true
    do {
      try await store.releaseDeliveryReservations(for: hostID)
      for id in try await store.abandonPreparedDeliveries(for: hostID) { notifyWritten(id) }
      for request in try await store.unsettledDeliveries(for: hostID) {
        guard started, !Task.isCancelled else { return }
        await finish(request, await recover(request), resuming: true)
      }
      guard started, !Task.isCancelled else { return }
      let next = try await deleteExpired()
      guard started, !Task.isCancelled else { return }
      if let next { scheduleCleanup(at: next) }
      roles.put(.watcher, .spawn { [store, hostID, onIssue] _ in
        do {
          for try await _ in store.observe({ try $0.pendingDeliveries(for: hostID).map(\.id) }) { self.enqueue() }
        } catch {
          if !Task.isCancelled { onIssue(error) }
        }
      })
    } catch {
      await stop()
      throw error
    }
  }

  public func stop() async {
    started = false
    let tasks = roles.cancelAll() + fetching.cancelAll() + waiting.cancelAll() + confirmations.cancelAll() + uploads.cancelAll()
    let previous = draining
    let drain = Task {
      await previous?.value
      for task in tasks { await task.value }
    }
    draining = drain
    await drain.value
  }

  private func enqueue() {
    guard started, !Task.isCancelled else { return }
    if roles.has(.runner) { rerun = true; return }
    roles.put(.runner, .spawn { id in await self.process(id) })
  }

  private func process(_ id: UUID) async {
    defer { roles.release(.runner, id) }
    repeat {
      rerun = false
      while started, !Task.isCancelled, let next = await nextActionable() { await run(next) }
    } while rerun && !Task.isCancelled
  }

  private func nextActionable() async -> Dispatch? {
    if let abandoned = await reporting({ try await store.abandonPreparedDeliveries(for: hostID) }) {
      for id in abandoned { notifyWritten(id) }
    }
    guard let candidates = await reporting({ try await store.pendingDeliveries(for: hostID) }) else { return nil }
    for request in candidates {
      if waiting.has(request.id) { continue }
      if request.deadlineAt.map({ timing.now() >= $0 }) == true || timing.now().timeIntervalSince(request.serverAt ?? request.createdAt) > Self.maxAge.seconds {
        let reason = request.status == .known(.preparing) ? DeliveryPreparation.expired : ShownText("请求到 iCloud 后超过 \(Int(Self.maxAge.seconds)) 秒仍未执行，已放弃")
        await finish(request, .failed(reason))
        continue
      }
      if case .unknown(let raw) = request.mode {
        await finish(request, .failed(ShownText("这个版本的 CuePad 不认识发送方式「\(raw)」，没有执行（可能来自更新版本，请升级 Mac 上的 CuePad）")))
        continue
      }
      let missing = request.attachmentKeys.filter { store.files.fileURL(for: $0) == nil }
      if !missing.isEmpty {
        if let prepared = await reporting({ try await store.prepareDelivery(request.id, until: timing.now().addingTimeInterval(Self.maxAge.seconds)) }) {
          if let prepared { fetch(missing, for: prepared) }
        }
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
        let deadline = timing.now().addingTimeInterval(Self.maxAge.seconds)
        switch access {
        case .existingOnly: return try await store.reserveDeliveryTarget(request.id, host: hostID, until: deadline)
        case .resumable: return try await store.claimDelivery(request.id, host: hostID, until: deadline)
        }
      }
      if let claimed = reserved, let claimed {
        let age = timing.now().timeIntervalSince(request.createdAt)
        Self.log.info("领取投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public)，创建后 \(age, format: .fixed(precision: 1)) 秒")
        return Dispatch(request: claimed, access: access)
      }
    }
    return nil
  }

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
      guard let begun = await reporting({ try await store.beginDelivery(request.id, on: hostID, until: timing.now().addingTimeInterval(Self.maxAge.seconds)) }),
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
    let outcome = try? await abandonable { [handler] in await handler(running, dispatch.access) }
    roles.cancel(.claimUpload)
    guard let outcome else { return }
    let took = timing.now().timeIntervalSince(began)
    Self.log.info("执行投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public) 用时 \(took, format: .fixed(precision: 2)) 秒")
    await finish(request, outcome)
  }

  /// 在旁边把这条请求的附件取齐：取到了再过一遍队列（文件不在库里，库的变化叫不醒执行器），取不来或过了期限按失败写回。
  /// 取附件的回调不一定响应取消或按时返回，所以与期限、停止都隔开等（`abandonable`）。
  private func fetch(_ keys: [String], for request: DeliveryRequest) {
    guard started, !Task.isCancelled, !fetching.has(request.id) else { return }
    let deadline = request.deadlineAt
    fetching.put(request.id, .spawn { [fetchFile, timing] id in
      let failure: ShownText?
      do {
        let wanted = Set(keys)
        let arrived = try await withThrowingTaskGroup(of: Bool.self) { group in
          for key in wanted { group.addTask { try await abandonable { try await fetchFile(key) }; return true } }
          if let deadline { group.addTask { try await timing.sleepUntil(deadline); return false } }
          defer { group.cancelAll() }
          var remaining = wanted.count
          while remaining > 0, let done = try await group.next() {
            if !done { return false }
            remaining -= 1
          }
          return true
        }
        failure = arrived ? nil : DeliveryPreparation.expired
      } catch {
        failure = ShownText(error)
      }
      await self.fetched(request, id, failure: failure)
    })
  }

  private func fetched(_ request: DeliveryRequest, _ id: UUID, failure: ShownText?) async {
    guard fetching.release(request.id, id) else { return }  // 停下了
    if let failure { await finish(request, .failed(failure)) }
    enqueue()
  }

  private func finish(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, resuming: Bool = false) async {
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

  private func prepare(_ request: DeliveryRequest, _ preparation: DeliveryPreparation) async {
    guard started, !Task.isCancelled, !waiting.has(request.id),
      let stored = await reporting({ try await store.awaitDeliveryTarget(request, reason: preparation.reason, until: timing.now().addingTimeInterval(Self.maxAge.seconds)) }),
      let stored, let deadline = stored.deadlineAt, started, !Task.isCancelled else { return }
    notifyWritten(stored.id)
    waiting.put(stored.id, .spawn { [store, timing] id in
      do {
        let ready = try await withThrowingTaskGroup(of: Bool.self) { group in
          group.addTask { try await abandonable { try await preparation.wait() }; return true }
          group.addTask { try await timing.sleepUntil(deadline); return false }
          group.addTask {
            for try await needed in store.observe({ store in
              let current = try store.deliveryRequest(stored.id)
              let abandoned = try store.isDeliveryAbandoned(stored.id)
              return current?.status == .known(.preparing) && current?.handledBy == nil && !abandoned
            }) {
              if !needed { return false }
            }
            return false
          }
          defer { group.cancelAll() }
          return try await group.next() ?? false
        }
        guard !Task.isCancelled else { return }
        for id in try await store.abandonPreparedDeliveries(for: self.hostID) { self.notifyWritten(id) }
        if timing.now() >= deadline {
          await self.finish(stored, .failed(DeliveryPreparation.expired))
        } else if ready {
          try await store.deliveryTargetReady(stored.id)
          self.notifyWritten(stored.id)
        }
      } catch {
        if !Task.isCancelled { await self.finish(stored, .failed(ShownText(error))) }
      }
      guard self.waiting.release(stored.id, id) else { return }
      self.enqueue()
    })
  }

  /// 上传回执也不占执行通道；同一条的版本顺序由同步发送器负责，这里只持有可取消任务。
  private func notifyWritten(_ id: UUID) {
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
  private func reporting<T>(_ operation: () async throws -> T) async -> T? {
    do { return try await operation() } catch {
      if !Task.isCancelled { onIssue(error) }
      return nil
    }
  }

  /// 发出的话与 Cue 的失败请求最多留多久（与对话的保留期一样是 7 天）。
  private static let keptRetention: TimeInterval = 7 * 86_400

  /// 在 `wake`（缺省是保留期后）清理一轮；已排了不晚于它的就不动，更晚的换成它——刚完成的请求的清理不能排在发出的话的 7 天后面。
  private func scheduleCleanup(at wake: Date? = nil) {
    guard started else { return }
    let wake = wake ?? timing.now().addingTimeInterval(Self.retention.seconds)
    if roles.has(.cleanup), let current = cleanupWake, current <= wake { return }
    roles.cancel(.cleanup)
    cleanupWake = wake
    roles.put(.cleanup, .spawn { [timing] id in
      guard (try? await timing.sleepUntil(wake)) != nil else { return }
      let next = await self.reporting { try await self.deleteExpired() }
      self.cleanupFinished(id, next: next)
    })
  }

  /// 清理一轮；返回下一轮该在什么时候做，没有剩下的为 nil：普通的完成请求一个保留期后，发出的话与 Cue 的失败请求等到它们的 7 天到期。
  private func deleteExpired() async throws -> Date? {
    let now = timing.now()
    let left = try await store.deleteCompletedDeliveries(
      before: now.addingTimeInterval(-Self.retention.seconds), claimCutoff: now.addingTimeInterval(-Self.maxAge.seconds),
      keptCutoff: now.addingTimeInterval(-Self.keptRetention))
    if left.transient { return now.addingTimeInterval(Self.retention.seconds) }
    return left.oldestKept.map { $0.addingTimeInterval(Self.keptRetention + 1) }  // 到期那一刻的判断是"晚于"，多留 1 秒
  }

  /// `next` 外层 nil 是这一轮读写失败：过一个保留期再来。
  private func cleanupFinished(_ id: UUID, next: Date??) {
    guard roles.release(.cleanup, id) else { return }
    cleanupWake = nil
    switch next {
    case .none: scheduleCleanup()
    case .some(let wake): if let wake { scheduleCleanup(at: wake) }
    }
  }
}
