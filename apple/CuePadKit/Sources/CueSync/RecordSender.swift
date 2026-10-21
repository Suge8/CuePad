import CloudKit
import CueStore
import Foundation
import Network
import os

/// 推：库里推导的待推送（`CueStore.pendingSync`）是唯一的队列，这里只决定什么时候发、一批发哪些。
///
/// 触发：本机提交让记录变成待推送（攒 `gatherWindow` 合成一批）、"马上传这几条"（`send`，这几条排在最前）、
/// 立即同步与回到前台（`kick`）、网络恢复。每批至多 `CloudKitLimits.recordsPerRequest` 条，`.ifServerRecordUnchanged`；结果交给协调器记账（`SyncCoordinator.sent`）。
/// 同一时刻只有一批在路上：同一条记录不会有两个版本同时上传、互相以版本冲突拒绝，结果也按发出的先后回来。
///
/// 失败：整个请求可重试的（离线、限流、服务忙）按服务器给的 `retryAfterSeconds` 或指数退避定时再发，网络恢复与明确的触发不等退避
/// （服务器给了 `retryAfterSeconds` 的除外）；配额、登录与未预期的失败停下，提交触发的先等 `blockedPause`，明确的触发照发。
actor RecordSender {
  static let gatherWindow = Duration.milliseconds(300)
  static let blockedPause = Duration.seconds(60)
  static let maxBackoff = Duration.seconds(300)
  /// 一轮至多发这么多批，余下的接着下一轮（防止被拒又处理不好的记录让一轮停不下来）。
  static let batchesPerRound = 100
  private static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  private let uploader: any RecordUploader
  private let coordinator: SyncCoordinator
  private let kicks: AsyncStream<Void>
  private let kick: AsyncStream<Void>.Continuation
  private var loop: Task<Void, Never>?
  private var commits: Task<Void, Never>?
  private var network: NWPathMonitor?

  private var first: Set<String> = []
  /// 下一轮是明确要求的（不攒窗口、不等停顿与退避）。
  private var explicit = false
  private var waiters: [(names: Set<String>, continuation: CheckedContinuation<Bool, Never>)] = []
  private var retry: Task<Void, Never>?
  private var failures = 0
  private var limit = CloudKitLimits.recordsPerRequest
  private var blockedUntil: ContinuousClock.Instant?
  /// 服务器要求在这之前别再发（`retryAfterSeconds`）。
  private var notBefore: ContinuousClock.Instant?

  init(uploader: any RecordUploader, coordinator: SyncCoordinator) {
    self.uploader = uploader
    self.coordinator = coordinator
    (kicks, kick) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// 开始跟随本机提交与网络变化，并立即发一轮（上次没发完的）。
  func start() async {
    let changes = await coordinator.store.syncChanges()  // 先订阅：返回后的提交都不会漏
    loop = Task { [kicks] in
      for await _ in kicks { await self.round() }
    }
    commits = Task { [kick] in
      for await _ in changes { kick.yield() }
    }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { await self?.networkReturned() }
    }
    monitor.start(queue: DispatchQueue(label: "\(AppIdentity.id).sync.network"))
    network = monitor
    poke()
  }

  func stop() {
    network?.cancel()
    network = nil
    commits?.cancel()
    loop?.cancel()
    retry?.cancel()
    for waiter in waiters { waiter.continuation.resume(returning: false) }
    waiters = []
  }

  /// 现在发一轮（立即同步、回到前台、进入后台前），返回时这一轮已结束。
  func flush() async {
    _ = await send([])
  }

  /// 马上传这几条：排在下一批的最前，等到它们所在的那一批有结果（收下为 true；离线等没传成的为 false，之后照常重试）。
  /// 空集合是不指定、发一轮，等这一轮结束。
  func send(_ names: Set<String>) async -> Bool {
    first.formUnion(names)
    return await withCheckedContinuation { continuation in
      waiters.append((names, continuation))
      poke()
    }
  }

  private func poke() {
    explicit = true
    kick.yield()
  }

  private func networkReturned() {
    guard retry != nil else { return }
    poke()
  }

  private enum End {
    /// 没有待推送了
    case done
    /// 一轮的批数用完，还有没发完的
    case more
    /// 停下（配额、登录、未预期的失败），或此刻不发（停顿、服务器要求的等待）
    case halted
    /// 到点再试
    case retry(at: ContinuousClock.Instant)
  }

  /// 一轮：一批接一批发到没有待推送、或停下来。
  private func round() async {
    if !explicit {
      try? await Task.sleep(for: Self.gatherWindow)  // 提交触发：同一阵子的写入合成一批
    }
    let wasExplicit = explicit
    explicit = false
    let now = ContinuousClock.now
    if let notBefore, now < notBefore { return finish(.retry(at: notBefore)) }
    if !wasExplicit, let blockedUntil, now < blockedUntil { return finish(.halted) }
    retry?.cancel()
    retry = nil
    blockedUntil = nil
    notBefore = nil

    let end = await batches()
    await coordinator.finishedSending()
    finish(end)
  }

  private func batches() async -> End {
    var zoneCreated = false
    for _ in 0..<Self.batchesPerRound {
      // 有一批要发才算同步中（`nextBatch` 交出时记下）：没有要传的一轮（每次拉取顺带的）界面不跟着闪
      guard let batch = await coordinator.nextBatch(first: first, limit: limit) else { return .done }
      let names = Set(batch.saves.map(\.recordID.recordName) + batch.deletes.map(\.recordName))
      first.subtract(names)
      do {
        let sent = try await uploader.upload(saving: batch.saves, deleting: batch.deletes)
        let outcome = await coordinator.sent(sent)
        resolve(names, received: Set(sent.saved.map(\.recordID.recordName) + sent.deleted.map(\.recordName)))
        if outcome.zoneMissing { try await uploader.saveZone() }
        if outcome.blocked {
          blockedUntil = .now + Self.blockedPause
          return .halted
        }
        // 有记录被限流、服务忙：这一轮到此为止，按服务器给的等待或退避再发，不立刻原样重传
        if let throttled = outcome.throttled {
          if let wait = throttled { notBefore = .now + wait }
          return .retry(at: .now + (throttled ?? backoff()))
        }
        if !outcome.progressed { return .retry(at: .now + backoff()) }
        failures = 0
      } catch let error as CKError where error.code == .limitExceeded && limit > 1 {
        first.formUnion(names)
        limit /= 2  // 这一批太大：减半再试
      } catch let error as CKError where error.code == .zoneNotFound && !zoneCreated {
        // 整个请求因同步区不在被拒（新装的第一次上传）：建区再发这一批
        first.formUnion(names)
        zoneCreated = true
        do { try await uploader.saveZone() } catch {
          resolve(names, received: [])
          return .retry(at: .now + backoff())
        }
      } catch {
        resolve(names, received: [])
        Self.log.notice("上传整批失败：\(error.brief, privacy: .public)")
        if let error = error as? CKError, error.code == .userDeletedZone {
          await coordinator.zoneMissing(deletedByUser: true)
          return .halted
        }
        await coordinator.reached(error)  // 网络类失败：连不上 iCloud
        guard let error = error as? CKError, Self.retryable.contains(error.code) else {
          if let error = error as? CKError { await coordinator.classify(error, recordName: nil) }
          blockedUntil = .now + Self.blockedPause
          return .halted
        }
        let wait = error.retryAfterSeconds.map { Duration.seconds($0) }
        if let wait { notBefore = .now + wait }
        return .retry(at: .now + (wait ?? backoff()))
      }
    }
    return .more
  }

  static let retryable = SyncCoordinator.offlineCodes.union([.requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable, .operationCancelled])

  private func backoff() -> Duration {
    failures += 1
    return min(.seconds(1 << min(failures, 9)), Self.maxBackoff)
  }

  /// 一轮结束：等着的有了答复（新的一轮已排上时留给它）；要重试的定好时间。
  private func finish(_ end: End) {
    if case .more = end { poke() }
    if !explicit {
      let ok = if case .done = end { true } else { false }
      for waiter in waiters { waiter.continuation.resume(returning: ok) }
      waiters = []
    }
    guard case .retry(let at) = end else { return }
    retry?.cancel()
    retry = Task {
      try? await Task.sleep(until: at, clock: .continuous)
      guard !Task.isCancelled else { return }
      self.poke()
    }
  }

  /// 一批有了结果：只等这批里的记录的调用方得到答复。
  private func resolve(_ names: Set<String>, received: Set<String>) {
    var rest: [(names: Set<String>, continuation: CheckedContinuation<Bool, Never>)] = []
    for waiter in waiters {
      if !waiter.names.isEmpty, waiter.names.isSubset(of: names) {
        waiter.continuation.resume(returning: waiter.names.isSubset(of: received))
      } else {
        rest.append(waiter)
      }
    }
    waiters = rest
  }
}
