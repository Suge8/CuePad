import CloudKit
import CueStore
import Foundation
import os

/// 推：库里推导的待推送（`CueStore.pendingSync`）是唯一的队列，这里只决定什么时候发、一批发哪些。
///
/// 两路：后台那一路随本机提交（攒 `gatherWindow` 合成一批）与立即同步（`kick`）一轮轮地发，每批至多 `CloudKitLimits.recordsPerRequest` 条；
/// 马上传（`send`，说的话、回执）另走一路，不进攒批窗口、不排在后台那批后面，当场只发这几条。同一条记录同一时刻只在一批里（`inFlight`）：
/// 不会有两个版本同时上传、互相以版本冲突拒绝。`.ifServerRecordUnchanged`；结果交给协调器记账（`SyncCoordinator.sent`）。
/// 开始上传前先对一次最低对端版本（`prepare`），成功为止；拉取不等它。
///
/// 服务器拒收的单条记录不挡别的：协调器记下这一版跳过它（`SyncCoordinator.unsendable`），这一批照常算有进展。
/// 整批的失败只有一个调度（`hold`）：协调器归类（`SyncFault`）后定下次最早什么时候发——连不上与账号按 `Backoff` 退避（有话在等时上限小），
/// 服务器要求的等待照它，整个请求被拒停 `rejectedPause`。立即同步与按节奏的拉取顺带的一轮都守这个时刻；只有连通的证据（任何一次请求成功、
/// 网络路径恢复）能提前结束连不上的等待。马上传与进后台前的那一轮（用户在等，试一次不费什么）越过连不上与被拒的等待，服务器要求的等待照守。
actor RecordSender {
  static let gatherWindow = Duration.milliseconds(300)
  static let rejectedPause = Duration.seconds(60)
  /// 一轮至多发这么多批，余下的接着下一轮（防止被拒又处理不好的记录让一轮停不下来）。
  static let batchesPerRound = 100
  private static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  private let uploader: any RecordUploader
  private let coordinator: SyncCoordinator
  private let prepare: @Sendable () async throws -> Void
  private let triggers: AsyncStream<Void>
  private let trigger: AsyncStream<Void>.Continuation
  private var tasks: [Task<Void, Never>] = []

  /// 下一轮不攒窗口（立即同步、重试到点、连通了）；`urgentRound` 另越过连不上与被拒的等待（进后台前，`admitted`）。
  private var explicit = false
  private var urgentRound = false
  /// 等下一轮结束的（`flush`）；轮开始时取走、轮结束时答复。
  private var flushes: [CheckedContinuation<Void, Never>] = []
  private var prepared = false
  private var preparing: Task<Bool, Never>?
  /// 在路上的（或马上传已占下的）记录名：另一路不再挑它们。
  private var inFlight: Set<String> = []
  /// 马上传了、还没收下的：有它们时退避上限小，到点先发它们。
  private var urgent: Set<String> = []
  private var waiters: [(remaining: Set<String>, received: Bool, continuation: CheckedContinuation<Bool, Never>)] = []
  private var urgentRuns: [Int: Task<Void, Never>] = [:]
  private var nextRun = 0
  private var backoff = Backoff()
  /// 下次最早什么时候发、因为什么，其中服务器给的最早时刻（连通的证据也不提前它）：唯一的重试调度。
  private var hold: (until: ContinuousClock.Instant, fault: SyncFault, notBefore: ContinuousClock.Instant)?
  private var retry: Task<Void, Never>?
  private var limit = CloudKitLimits.recordsPerRequest
  private var busy = false

  init(uploader: any RecordUploader, coordinator: SyncCoordinator, prepare: @escaping @Sendable () async throws -> Void = {}) {
    self.uploader = uploader
    self.coordinator = coordinator
    self.prepare = prepare
    (triggers, trigger) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// 开始跟随本机提交、连通的证据与网络变化，并立即发一轮（上次没发完的）。
  func start() async {
    let changes = await coordinator.store.syncChanges()  // 先订阅：返回后的提交都不会漏
    let connectivity = coordinator.connectivity.stream()
    let network = NetworkReturns.stream()
    tasks = [
      Task { [triggers] in for await _ in triggers { await self.round() } },
      Task { [trigger] in for await _ in changes { trigger.yield() } },
      Task { for await _ in connectivity { self.connected() } },
      Task { for await _ in network { self.connected() } },
    ]
    kick()
  }

  func stop() {
    tasks.forEach { $0.cancel() }
    retry?.cancel()
    for waiter in waiters { waiter.continuation.resume(returning: false) }
    waiters = []
    for flush in flushes { flush.resume() }
    flushes = []
  }

  /// 发一轮（立即同步、按节奏的拉取顺带的），不等；守着重试的时刻。
  func kick() {
    explicit = true
    trigger.yield()
  }

  /// 现在发一轮并等它结束，连同在路上的马上传（iOS 进入后台前）：越过连不上与被拒的等待试一次，服务器要求的等待照守。
  /// 挂住的请求至多到 CloudKit 的超时（`RequestLimits.request`），在系统给的后台时间之内。
  func flush() async {
    let sending = Array(urgentRuns.values)
    await withCheckedContinuation { continuation in
      flushes.append(continuation)
      urgentRound = true
      kick()
    }
    for run in sending { await run.value }
  }

  /// 马上传这几条：不进攒批窗口，不等后台那批，等到它们都有了结果（全收下为 true；离线等没传成的为 false，之后照常重试，且优先）。
  func send(_ names: Set<String>) async -> Bool {
    urgent.formUnion(names)
    return await withCheckedContinuation { continuation in
      waiters.append((names, true, continuation))
      runUrgent()
    }
  }

  /// 马上传那一路发一次，记着在跑的（`flush` 等它们）。
  @discardableResult
  private func runUrgent() -> Task<Void, Never> {
    let id = nextRun
    nextRun += 1
    let run = Task {
      await sendUrgent()
      urgentRuns[id] = nil
    }
    urgentRuns[id] = run
    return run
  }

  // MARK: 两路

  /// 后台那一路的一轮：一批接一批发到没有待推送、或要等。
  private func round() async {
    if !explicit {
      try? await Task.sleep(for: Self.gatherWindow)  // 提交触发：同一阵子的写入合成一批
    }
    let urgent = urgentRound
    (explicit, urgentRound) = (false, false)
    let waiting = flushes
    flushes = []
    defer { waiting.forEach { $0.resume() } }
    guard admitted(urgent: urgent), await coordinator.canSync, await ready() else { return }
    for _ in 0..<Self.batchesPerRound {
      guard admitted(urgent: urgent) else { return }  // 另一路这期间被要求等了
      // 准备不了（停下了、读库出错）由协调器记下状态，下一次触发再来
      guard var batch = try? await coordinator.nextBatch(.pending(excluding: inFlight), limit: limit) else { return }
      batch.drop(inFlight)  // 挑的时候马上传那一路占下的
      guard !batch.isEmpty else { return }
      guard await upload(batch) else { return }
    }
    kick()  // 一轮的批数用完，还有没发完的
  }

  /// 马上传那一路：只发在等的这几条里不在路上的；在路上的等那一批的结果。已不是待推送的答收下了，这一版传不上去的答没传成、不再追；
  /// 一批装不下的这一批收下后接着发，这一批没成就一起答没传成（仍在 `urgent` 里，重试时先发）。
  private func sendUrgent() async {
    let wanted = urgent.subtracting(inFlight)
    guard !wanted.isEmpty else { return }
    guard admitted(urgent: true), await coordinator.canSync, await ready() else { return answer(wanted, received: []) }
    let reserved = wanted.subtracting(inFlight)  // 等的时候后台那一路可能已带走
    inFlight.formUnion(reserved)
    let prepared = try? await coordinator.nextBatch(.only(reserved), limit: limit)
    inFlight.subtract(reserved)
    guard let batch = prepared else { return answer(reserved, received: []) }  // 准备不了：之后照常重试
    let settled = reserved.subtracting(batch.names).subtracting(batch.stuck).subtracting(batch.left)  // 已不是待推送（别的批已收下、删掉了）
    answer(settled, received: settled)
    answer(batch.stuck, received: [])
    urgent.subtract(settled.union(batch.stuck))
    guard !batch.isEmpty else { return }
    let sent = await upload(batch)
    trigger.yield()  // 在路上时又改过的，后台那一路接着发
    guard !batch.left.isEmpty else { return }
    if sent { runUrgent() } else { answer(batch.left, received: []) }
  }

  /// 发一批；返回能不能接着发下一批。
  private func upload(_ batch: OutgoingBatch) async -> Bool {
    let names = batch.names
    inFlight.formUnion(names)
    await updateBusy()
    let next = await outcome(of: batch)
    inFlight.subtract(names)
    await updateBusy()
    return next
  }

  private func outcome(of batch: OutgoingBatch) async -> Bool {
    let names = batch.names
    do {
      var sent: SentRecords
      do {
        sent = try await uploader.upload(saving: batch.saves, deleting: batch.deletes)
      } catch let error as CKError where error.code == .zoneNotFound {
        // 整个请求因同步区不在被拒（新装的第一次上传）：建区再发这一批
        try await uploader.saveZone()
        sent = try await uploader.upload(saving: batch.saves, deleting: batch.deletes)
      }
      let outcome = await coordinator.sent(sent, for: batch)
      answer(names, received: Set(sent.saved.map(\.recordID.recordName) + sent.deleted.map(\.recordName)))
      if outcome.zoneMissing { try await uploader.saveZone() }
      if let fault = outcome.fault {
        schedule(fault)
        return false
      }
      guard outcome.progressed else {
        schedule(.wait(nil))
        return false
      }
      backoff.reset()
      settled()
      return true
    } catch let error as CKError where error.code == .limitExceeded && limit > 1 {
      limit /= 2  // 这一批太大：减半再试（马上传那一路的由后台那一路接着发）
      answer(names, received: [])
      return true
    } catch {
      answer(names, received: [])
      Self.log.notice("上传整批失败：\(error.brief, privacy: .public)")
      if let error = error as? CKError, error.code == .userDeletedZone {
        await coordinator.zoneMissing(deletedByUser: true)
        return false
      }
      schedule(await coordinator.failed(error))
      return false
    }
  }

  /// 上传前对一次最低对端版本，成功为止（同一时刻只对一次）；停下（这台要更新、要你决定）的不再对。
  private func ready() async -> Bool {
    if prepared { return true }
    if let preparing { return await preparing.value }
    let task = Task { () -> Bool in
      do {
        try await prepare()
        return true
      } catch is SyncPaused {
        return false
      } catch {
        Self.log.notice("对最低对端版本失败，暂不上传：\(error.brief, privacy: .public)")
        schedule(await coordinator.failed(error))
        return false
      }
    }
    preparing = task
    prepared = await task.value
    preparing = nil
    return prepared
  }

  // MARK: 重试调度

  /// 此刻能不能发：没有在等的，或是用户在等的一轮（`urgent`）而等的是连不上或整个请求被拒、服务器给的最早时刻已过。
  private func admitted(urgent: Bool) -> Bool {
    let now = ContinuousClock.now
    guard let hold, now < hold.until else { return true }
    guard urgent, now >= hold.notBefore else { return false }
    return switch hold.fault {
    case .offline, .rejected: true
    case .wait, .account: false
    }
  }

  /// 定下次最早什么时候发（见类型注释）。
  private func schedule(_ fault: SyncFault) {
    let now = ContinuousClock.now
    let cap = urgent.isEmpty ? nil : Backoff.waitingCap
    // 另一路先前得到的服务器等待照守：两路的结果先后回来，后到的不缩短它
    let notBefore = max(now + (fault.retryAfter ?? .zero), hold?.notBefore ?? now)
    let until: ContinuousClock.Instant =
      switch fault {
      case .offline: now + backoff.next(cap: cap)
      case .wait(let given): given.map { now + $0 } ?? now + backoff.next(cap: cap)
      case .account: now + backoff.next()
      case .rejected: now + Self.rejectedPause
      }
    hold = (max(until, notBefore), fault, notBefore)
    wake(at: max(until, notBefore))
  }

  private func wake(at until: ContinuousClock.Instant) {
    retry?.cancel()
    retry = Task {
      try? await Task.sleep(until: until, clock: .continuous)
      guard !Task.isCancelled else { return }
      self.resume()
    }
  }

  /// 有一批收下了：退避的等待到此为止，服务器给的最早时刻照守（另一路被限流时它还在）。
  private func settled() {
    guard let hold, ContinuousClock.now < hold.notBefore else { return clearHold() }
    self.hold = (hold.notBefore, hold.fault, hold.notBefore)
    wake(at: hold.notBefore)
  }

  private func clearHold() {
    hold = nil
    retry?.cancel()
    retry = nil
  }

  /// 到点或连通了：有话在等先只发它们，成了再发一轮后台的（没成就又定了时刻，那一轮守着它）：断网时每次重试只一个请求。
  private func resume() {
    guard !urgent.isEmpty else { return kick() }
    let run = runUrgent()
    Task {
      await run.value
      kick()
    }
  }

  /// 连通的证据（任何一次请求成功、网络路径恢复）：因连不上在等的不再等退避，服务器给的最早时刻照守。
  private func connected() {
    guard let hold, hold.fault.isOffline else { return }
    guard ContinuousClock.now >= hold.notBefore else {
      self.hold?.until = hold.notBefore
      return wake(at: hold.notBefore)
    }
    clearHold()
    resume()
  }

  /// 同步中：有一批在路上，或服务器要求等着重发（连不上、账号、出错各有自己的状态）。
  private func updateBusy() async {
    let waiting = if case .wait = hold?.fault { true } else { false }
    let now = !inFlight.isEmpty || waiting
    guard now != busy else { return }
    busy = now
    await coordinator.setSending(now)
  }

  /// 一批有了结果：在等的话里这批带着的有了答复，都有答复的等待者返回（全收下才是 true）。
  private func answer(_ names: Set<String>, received: Set<String>) {
    urgent.subtract(received)
    var rest: [(remaining: Set<String>, received: Bool, continuation: CheckedContinuation<Bool, Never>)] = []
    for var waiter in waiters {
      let hit = waiter.remaining.intersection(names)
      waiter.received = waiter.received && hit.isSubset(of: received)
      waiter.remaining.subtract(hit)
      if waiter.remaining.isEmpty { waiter.continuation.resume(returning: waiter.received) } else { rest.append(waiter) }
    }
    waiters = rest
  }
}

extension OutgoingBatch {
  var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }

  /// 去掉这几条（另一批已带走）：这批就不再是"全部"。
  mutating func drop(_ names: Set<String>) {
    guard !names.isDisjoint(with: self.names) else { return }
    saves.removeAll { names.contains($0.recordID.recordName) }
    deletes.removeAll { names.contains($0.recordName) }
    drains = nil
  }
}
