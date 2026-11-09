import CloudKit
import CueStore
import Foundation

/// 这里只决定什么时候发、一批发哪些；附件的文件不在这里传（`FileSender`）。
/// 同一条记录同一时刻只在一批里（`inFlight`）：不会有两个版本同时上传、互相以 `.ifServerRecordUnchanged` 的版本冲突拒绝。
/// `stop` 取消并等在途的轮次与请求收尾才返回：之后不再挑、不再发，接手的新发送者不会与旧的同时传同一条记录。
/// 服务器拒收的单条记录不挡别的：协调器记下这一版跳过它（`SyncCoordinator.unsendable`），这一批照常算有进展。
/// 整批的失败交给同步层唯一的重试调度（协调器的 `hold`，与拉取共用），等待结束时（`retryDue`）接着发。
/// 马上传与进后台前的那一轮（用户在等，试一次不费什么）越过连不上与被拒的等待，服务器要求的等待照守。
actor RecordSender {
  static let gatherWindow = Duration.milliseconds(300)
  /// 一轮至多发这么多批，余下的接着下一轮（防止被拒又处理不好的记录让一轮停不下来）。
  static let batchesPerRound = 100

  private let uploader: any RecordUploader
  private let coordinator: SyncCoordinator
  private let prepare: @Sendable () async throws -> Void
  private let step: @Sendable (Step) async -> Void
  /// 测试控制先后的两处：后台那一路挑完一批、进 `inFlight` 之前；马上传那一路占下之前。
  enum Step { case picked, reserving }
  private let triggers: AsyncStream<Void>
  private let trigger: AsyncStream<Void>.Continuation
  private var tasks: [Task<Void, Never>] = []

  private var explicit = false
  private var urgentRound = false
  /// 停下时随这一代结束一起答（`SyncGeneration.value`）。
  private var flushes: [Promise<Void>] = []
  private var prepared = false
  private var preparing: Task<Bool, Never>?
  /// 在路上的（或马上传已占下的）记录名：另一路不再挑它们。测试读它控制先后。
  private(set) var inFlight: Set<String> = []
  /// 马上传了、还没收下的（含答过没传成的）：有它们时退避上限小，到点先发它们。
  private var urgent: Set<String> = []
  /// 每次要马上传加一。一批只答读库之前要的（`Waiter.asked <= readAt`）：之后要的，这一批读到的可能早于它要的那一版
  /// （刚领取的投送请求，结果紧跟着写下；后台那一路读库在先、进 `inFlight` 在后）。没答的等这几条离开 `inFlight` 时补发（`release`）。
  private var asks = 0
  /// 谁还在等哪几条，只记在这里。停下时随这一代结束一起答。
  private var waiters: [Waiter] = []
  private struct Waiter {
    let asked: Int
    var remaining: Set<String>
    var received = true
    let answer = Promise<Bool>()
  }
  private var urgentRuns: [Int: Task<Void, Never>] = [:]
  private var nextRun = 0
  private var limit = CloudKitLimits.recordsPerRequest
  private var busy = false
  private let generation: SyncGeneration
  private var stopped: Bool { generation.isOver }

  /// `step` 只给测试控制先后（`Step`）。
  init(
    uploader: any RecordUploader, coordinator: SyncCoordinator, generation: SyncGeneration = SyncGeneration(),
    prepare: @escaping @Sendable () async throws -> Void = {}, step: @escaping @Sendable (Step) async -> Void = { _ in }
  ) {
    self.uploader = uploader
    self.coordinator = coordinator
    self.generation = generation
    self.prepare = prepare
    self.step = step
    (triggers, trigger) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  func start() async {
    let changes = await coordinator.store.syncChanges()  // 先订阅：返回后的提交都不会漏
    guard !stopped else { return }  // 订阅期间停下了
    let due = coordinator.retryDue.stream()
    tasks = [
      Task { [triggers] in for await _ in triggers { await self.round() } },
      Task { [trigger] in
        for await tables in changes {
          if tables.contains(.cueMessages) { await self.speak() }
          trigger.yield()
        }
      },
      Task { for await _ in due { self.resume() } },
    ]
    kick()
  }

  func stop() async {
    generation.end()
    let running = tasks + Array(urgentRuns.values)
    let preparation = preparing
    tasks = []
    preparation?.cancel()
    running.forEach { $0.cancel() }
    for task in running { await task.value }
    _ = await preparation?.value
  }

  /// 不等；守着重试的时刻。
  func kick() {
    guard !stopped else { return }
    explicit = true
    trigger.yield()
  }

  /// 现在发一轮并等它结束，连同在路上的马上传：越过连不上与被拒的等待试一次，服务器要求的等待照守。
  /// 挂住的请求至多到 CloudKit 的超时（`RequestLimits.request`），在系统给的后台时间之内。
  func flush() async {
    guard !stopped else { return }
    let sending = Array(urgentRuns.values)
    let done = Promise<Void>()
    flushes.append(done)
    urgentRound = true
    kick()
    try? await generation.value(of: done, cancellable: false)
    for run in sending { await run.value }
  }

  /// 马上传这几条：不进攒批窗口，不等后台那批，等到它们都有了结果（全收下为 true；离线等没传成的为 false，之后照常重试，且优先；空集当场 true）。
  /// 收下指服务器收下的不早于此刻库里的这一版。
  /// 调用方被取消也不提前返回（`cancellable: false`，等的是多方共用的那次上传），最长到 CloudKit 的请求超时：不要在任务组里拿它跟到点比快，
  /// 输的一方等不了，组返回不了。要设时限就用 `abandonable` 包住它，或照 `DiagnosticOutbox.reconcile(within:)`：事件流加一个定时 Task，谁先 yield 谁赢。
  func send(_ names: Set<String>) async -> Bool {
    guard !names.isEmpty else { return true }
    guard !stopped else { return false }
    urgent.formUnion(names)
    asks += 1
    let waiter = Waiter(asked: asks, remaining: names)
    waiters.append(waiter)
    runUrgent()
    return (try? await generation.value(of: waiter.answer, cancellable: false)) ?? false
  }

  /// Cue 对你说的话还没传的马上传：多半是命令行进程里 Cue 的工具写的，写的人叫不了上传。
  private func speak() async {
    guard let names = try? await coordinator.store.pendingSpeech(), !names.subtracting(urgent).isEmpty else { return }
    Task { _ = await send(names) }
  }

  @discardableResult
  private func runUrgent() -> Task<Void, Never> {
    guard !stopped else { return Task {} }
    let id = nextRun
    nextRun += 1
    let run = Task {
      await sendUrgent()
      urgentRuns[id] = nil
    }
    urgentRuns[id] = run
    return run
  }

  private func round() async {
    if !explicit {
      try? await Task.sleep(for: Self.gatherWindow)  // 提交触发：同一阵子的写入合成一批
    }
    guard !stopped else { return }
    let urgent = urgentRound
    (explicit, urgentRound) = (false, false)
    let waiting = flushes
    flushes = []
    defer { waiting.forEach { $0.resolve(.success(())) } }
    guard await coordinator.admits(.upload(urgent: urgent)), await coordinator.canSync, await ready() else { return }
    for _ in 0..<Self.batchesPerRound {
      guard !stopped, await coordinator.admits(.upload(urgent: urgent)) else { return }  // 另一路这期间被要求等了
      // 准备不了（停下了、读库出错）由协调器记下状态，下一次触发再来
      let readAt = asks
      guard var batch = try? await coordinator.nextBatch(.pending(excluding: inFlight), limit: limit) else { return }
      await step(.picked)
      batch.drop(inFlight)  // 挑的时候马上传那一路占下的
      guard !batch.isEmpty else { return }
      guard await upload(batch, readAt: readAt) else { return }
    }
    kick()  // 一轮的批数用完，还有没发完的
  }

  /// 马上传那一路：只发在等的这几条里不在路上的；在路上的等那一批的结果。已不是待推送的答收下了，这一版传不上去的答没传成、不再追；
  /// 一批装不下的这一批收下后接着发，这一批没成就一起答没传成（仍在 `urgent` 里，重试时先发）。
  private func sendUrgent() async {
    let wanted = waited.union(urgent).subtracting(inFlight)
    guard !stopped, !wanted.isEmpty else { return }
    guard await coordinator.admits(.upload(urgent: true)), await coordinator.canSync, await ready() else {
      return answer(wanted, received: [], readAt: asks)
    }
    await step(.reserving)
    let reserved = wanted.subtracting(inFlight)  // 等的时候后台那一路可能已带走
    let readAt = asks
    inFlight.formUnion(reserved)
    guard let batch = try? await coordinator.nextBatch(.only(reserved), limit: limit) else {  // 准备不了：之后照常重试
      answer(reserved, received: [], readAt: readAt)
      return release(reserved)
    }
    let settled = reserved.subtracting(batch.names).subtracting(batch.stuck).subtracting(batch.left)  // 已不是待推送（别的批已收下、删掉了）
    answer(settled, received: settled, readAt: readAt)
    answer(batch.stuck, received: [], readAt: readAt)
    urgent.subtract(batch.stuck)
    guard !batch.isEmpty, !stopped else {
      answer(batch.names, received: [], readAt: readAt)
      return release(reserved)
    }
    release(reserved.subtracting(batch.names).subtracting(batch.left))
    let sent = await upload(batch, readAt: readAt)
    trigger.yield()  // 在路上时又改过的，后台那一路接着发
    if !sent { answer(batch.left, received: [], readAt: readAt) }
    release(batch.left)  // 这一批收下了，装不下的接着发
  }

  /// 发一批；返回能不能接着发下一批。`readAt`：这一批读库之前的 `asks`。
  private func upload(_ batch: OutgoingBatch, readAt: Int) async -> Bool {
    let names = batch.names
    inFlight.formUnion(names)
    await updateBusy()
    let next = await outcome(of: batch, readAt: readAt)
    release(names)
    await updateBusy()
    return next
  }

  /// 还有人在等的记录名。测试读它控制先后。
  var waited: Set<String> { waiters.reduce(into: []) { $0.formUnion($1.remaining) } }

  /// 这几条离开 `inFlight`：还有人在等的（读库之后才要的、核对时已作废的、这一批没带上的）补发一趟，读库在那之后，答得了它们。
  /// 补发的那一趟挑不到在路上的，所以只在离开时补：在路上时补，就没人再发，在等的要等到这条记录下次被改。
  private func release(_ names: Set<String>) {
    inFlight.subtract(names)
    guard waiters.contains(where: { !$0.remaining.isDisjoint(with: names) }) else { return }
    runUrgent()
  }

  private func outcome(of prepared: OutgoingBatch, readAt: Int) async -> Bool {
    var names = prepared.names
    do {
      let (batch, _) = try await coordinator.reserveForUpload(prepared)  // 作废的仍有人等就由 `release` 补发
      names = batch.names
      guard !batch.isEmpty else { return true }
      var sent: SentRecords
      do {
        sent = try await uploader.upload(saving: batch.saves, deleting: batch.deletes)
      } catch let error as CKError where error.code == .zoneNotFound {
        try await uploader.saveZone()
        sent = try await uploader.upload(saving: batch.saves, deleting: batch.deletes)
      }
      let outcome = await coordinator.sent(sent, for: batch)
      answer(names, received: Set(sent.saved.map(\.recordID.recordName) + sent.deleted.map(\.recordName)), readAt: readAt)
      if outcome.paused { return false }  // 协调器停下了（等你决定、要更新）：结果没记账，也不定重试时刻
      if outcome.zoneMissing { try await uploader.saveZone() }
      if let fault = outcome.fault {
        await schedule(fault)
        return false
      }
      guard outcome.progressed else {
        await schedule(.wait(nil))
        return false
      }
      await coordinator.progressed()
      return true
    } catch let error as CKError where error.code == .limitExceeded && limit > 1 {
      limit /= 2  // 这一批太大：减半再试（马上传那一路的由后台那一路接着发）
      answer(names, received: [], readAt: readAt)
      return true
    } catch {
      answer(names, received: [], readAt: readAt)
      if stopped { return false }  // 停下时被取消的请求不是同步的失败，不记
      if let error = error as? CKError, error.code == .userDeletedZone {
        await coordinator.zoneMissing(deletedByUser: true)
        return false
      }
      await schedule(await coordinator.failed(error))
      return false
    }
  }

  /// 上传前对一次最低对端版本，成功为止（同一时刻只对一次）；停下的不再对。文件那一路（`FileSender`）同样等它。
  func ready() async -> Bool {
    guard !stopped else { return false }
    if prepared { return true }
    if let preparing { return await preparing.value }
    let task = Task { () -> Bool in
      do {
        try await prepare()
        return true
      } catch is SyncPaused {
        return false
      } catch {
        if !stopped { await schedule(await coordinator.failed(error)) }
        return false
      }
    }
    preparing = task
    prepared = await task.value
    preparing = nil
    return prepared
  }

  private func schedule(_ fault: SyncFault) async {
    await coordinator.hold(fault, waiting: !urgent.isEmpty)
  }

  /// 有话在等先只发它们，成了再发后台那一轮：断网时每次重试只一个请求。
  private func resume() {
    guard !stopped else { return }
    guard !urgent.isEmpty else { return kick() }
    let run = runUrgent()
    Task {
      await run.value
      kick()
    }
  }

  private func updateBusy() async {
    let now = !inFlight.isEmpty
    guard now != busy else { return }
    busy = now
    await coordinator.setSending(now)
  }

  private func answer(_ names: Set<String>, received: Set<String>, readAt: Int) {
    var rest: [Waiter] = []
    for var waiter in waiters {
      let hit = waiter.asked <= readAt ? waiter.remaining.intersection(names) : []
      waiter.received = waiter.received && hit.isSubset(of: received)
      waiter.remaining.subtract(hit)
      if waiter.remaining.isEmpty { waiter.answer.resolve(.success(waiter.received)) } else { rest.append(waiter) }
    }
    waiters = rest
    urgent.subtract(names.intersection(received).subtracting(waited))
  }
}

extension OutgoingBatch {
  var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }

  /// 另一批已带走的去掉后，这批就不再是"全部"。
  mutating func drop(_ names: Set<String>) {
    guard !names.isDisjoint(with: self.names) else { return }
    saves.removeAll { names.contains($0.recordID.recordName) }
    deletes.removeAll { names.contains($0.recordName) }
    drains = nil
  }
}
