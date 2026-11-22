import Foundation
import os

public actor DeliveryExecutor {
  let store: CueStore
  let hostID: String
  package static let retention: Duration = .seconds(60)
  let timing: Timing
  private let onIssue: @Sendable (any Error) -> Void
  private let recover: @Sendable (DeliveryRequest) async -> DeliveryOutcome
  private let preparation: @Sendable (DeliveryRequest) async -> DeliveryAdmission
  var waiting = Slots<DeliveryRequest.ID>()
  private let handler: @Sendable (DeliveryRequest, DeliveryAdmission.Access) async -> DeliveryOutcome
  let fetchFile: @Sendable (String) async throws -> Void
  private var confirmations = Slots<DeliveryRequest.ID>()
  var fetching = Slots<DeliveryRequest.ID>()
  private static let log = Logger(subsystem: AppIdentity.id, category: "delivery")
  var started = false
  enum Role { case starting, watcher, expiry, cleanup, runner }
  var roles = Slots<Role>()
  private var draining: Task<Void, Never>?
  private var rerun = false
  private var handling: Task<DeliveryOutcome, Never>?
  var cleanupWake: Date?
  private var startFailure: (any Error)?

  public init(
    store: CueStore, hostID: String,
    timing: Timing = .system, onIssue: @escaping @Sendable (any Error) -> Void,
    fetchFile: @escaping @Sendable (String) async throws -> Void = { _ in throw CueStoreError.notFound },
    recover: @escaping @Sendable (DeliveryRequest) async -> DeliveryOutcome = { _ in .unconfirmed(DeliveryRequest.interruptedReason) },
    preparation: @escaping @Sendable (DeliveryRequest) async -> DeliveryAdmission = { _ in .ready(.resumable) },
    handler: @escaping @Sendable (DeliveryRequest, DeliveryAdmission.Access) async -> DeliveryOutcome
  ) {
    self.store = store
    self.hostID = hostID
    self.timing = timing
    self.onIssue = onIssue
    self.preparation = preparation
    self.handler = handler
    self.recover = recover
    self.fetchFile = fetchFile
  }

  public func start() async throws {
    await draining?.value
    try Task.checkCancellation()
    guard !started else { return }
    started = true
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
      try await store.abandonPreparedDeliveries(for: hostID)
      for request in try await store.unsettledDeliveries(for: hostID) {
        guard started, !Task.isCancelled else { return }
        guard let outcome = await perform({ [recover] in await recover(request) }) else { return }
        await finish(request, outcome, resuming: true)
      }
      guard started, !Task.isCancelled else { return }
      let next = try await store.deleteExpiredDeliveries(at: timing.now(), host: hostID)
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
    let tasks = roles.cancelAll() + fetching.cancelAll() + waiting.cancelAll() + confirmations.cancelAll()
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
    await reporting { try await store.abandonPreparedDeliveries(for: hostID) }
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
      if request.mode == .known(.withdraw) {
        await reporting { try await store.settleWithdrawal(request, on: hostID) }
        scheduleCleanup()
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
      let claimed = await reporting {
        try await store.claimDelivery(request.id, host: hostID, until: timing.now().addingTimeInterval(DeliveryRequest.phaseLimit))
      }
      if let claimed, let claimed {
        let age = timing.now().timeIntervalSince(request.createdAt)
        Self.log.info("领取投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public)，创建后 \(age, format: .fixed(precision: 1)) 秒")
        return Dispatch(request: claimed, access: access)
      }
      if isExpired(request) { await finish(request, .failed(request.expiry)) }
    }
    return nil
  }

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
    let request = dispatch.request
    let began = timing.now()
    let running = request
    let outcome = await perform(until: request.deadlineAt) { [handler] in await handler(running, dispatch.access) }
    guard let outcome else { return }
    let took = timing.now().timeIntervalSince(began)
    Self.log.info("执行投送请求 \(request.id.uuidString.prefix(8), privacy: .public) \(request.mode.rawValue, privacy: .public) 用时 \(took, format: .fixed(precision: 2)) 秒")
    await finish(request, outcome)
  }

  func finish(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, resuming: Bool = false) async {
    guard started, !Task.isCancelled else { return }
    let continuing: Bool = if case .confirming = outcome { resuming && request.status != .known(.executing) } else { false }
    if !continuing {
      await reporting { try await store.finishDelivery(request, outcome, at: timing.now(), resuming: resuming) }
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

  @discardableResult
  func reporting<T>(_ operation: () async throws -> T) async -> T? {
    do { return try await operation() } catch {
      if !Task.isCancelled { onIssue(error) }
      return nil
    }
  }
}
