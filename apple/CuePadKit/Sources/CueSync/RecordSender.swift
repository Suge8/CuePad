import CloudKit
import CueStore
import Foundation

/// 这里只决定什么时候发、一批发哪些；附件的文件不在这里传（`FileSender`）。
/// 记录按表分两条通道（`Lane`，哪张表走哪条只看 `Table.live`），各自一轮一轮地挑批、发，一轮里同一时刻一批，挑全部待推送。
/// 要马上传的不进轮次：另加塞一批（`express`），只挑一写下就该传的版本，不等攒批窗口、不等这一轮在路上的那批
/// （Cue 的回话常紧跟在你那句的送达与会话结果之后写下，等它一个来回模拟云实测要多 0.3 秒）；领取、会话进展这些不急的版本照常等窗口。
/// 实时通道的一批小、新写的排在前面，积压再多，新写的也在下一批里；两条通道的表不相交，后台的大批挡不住实时通道里的哪一版。
/// 在路上的记录名记在通道里（`LaneState.inFlight`），挑批时跳过：同一条记录同一时刻至多一版在路上，
/// 不会两版互相以 `.ifServerRecordUnchanged` 的版本冲突拒绝。
///
/// 每条通道的轮次（`LaneState`）：
///
/// | 状态 | 触发 | 去向 |
/// |---|---|---|
/// | 闲着 | 提交碰了这条通道的表、不急 | 攒批 |
/// | 闲着 | 开始、`kick`、`flush`、等待结束（`retryDue`，先实时、跑完再后台）、加塞发完还有人在等 | 跑一轮 |
/// | 攒批 | 窗口（`gatherWindow`）到点，或其间来了上面那几种 | 跑一轮 |
/// | 跑一轮 | 挑一批（`SyncCoordinator.nextBatch`）、发，收下了接着挑 | 挑空、被等待挡下、发不成：闲着 |
/// | 跑一轮 | 其间又来了任何触发（`again`） | 跑完接着再跑一轮 |
///
/// 加塞（任何状态下）：实时通道的提交要马上传（`SyncChange.urgent`），或 `send` 在等 → 挑一批发出 → 这条通道攒批（有人在等就跑一轮）。
///
/// 越过连不上与被拒的等待（`SyncCoordinator.admits` 的 urgent）只给加塞的那批、`flush`、有 `send` 在等的那批；
/// 积压（开始时就在的、换账号或首次同步后的全部历史）照常退避。退避上限压到 `Backoff.waitingCap` 只在有 `send` 在等结果时。
/// `stop` 取消并等在途的轮次与请求收尾才返回：之后不再挑、不再发，接手的新发送者不会与旧的同时传同一条记录。
/// 服务器拒收的单条记录不挡别的：协调器记下这一版跳过它（`SyncCoordinator.unsendable`），这一批照常算有进展。
/// 整批的失败交给同步层唯一的重试调度（协调器的 `hold`，与拉取共用），等待结束时（`retryDue`）接着发。
actor RecordSender {
  static let gatherWindow = Duration.milliseconds(300)
  /// 一轮至多发这么多批，余下的接着下一轮（防止被拒又处理不好的记录让一轮停不下来）。
  static let batchesPerRound = 100
  /// 一批太大（`limitExceeded`）就减半；之后连着这么多批整批收下再翻倍，回到通道的上限为止：太大的多半是那几条大记录，它们传走了批量该回来。
  static let regrowAfter = 4

  private let uploader: any RecordUploader
  private let coordinator: SyncCoordinator
  private let prepare: @Sendable () async throws -> Void
  private var tasks: [Task<Void, Never>] = []
  private var lanes: [Lane: LaneState] = Dictionary(uniqueKeysWithValues: Lane.allCases.map { ($0, LaneState(limit: $0.limit)) })

  private struct LaneState {
    var running: Task<Void, Never>?
    var gathering: Task<Void, Never>?
    var again = false
    /// 下一轮越过连不上与被拒的等待（`flush`）。
    var urgent = false
    /// 在路上的记录名（这一轮的那批与加塞的那几批，`express`）。
    var inFlight: Set<String> = []
    var limit: Int
    var acceptedInARow = 0
  }
  /// 加塞的一批（`express`），停下时一起等。
  private var expresses: [Int: Task<Void, Never>] = [:]
  private var nextExpress = 0

  /// 每次 `send` 加一。一批只答读库之前要的（`Waiter.asked <= readAt`）：之后要的，这一批读到的可能早于它要的那一版。
  private var asks = 0
  /// 谁还在等哪几条（各在哪条通道），只记在这里。停下时随这一代结束一起答。
  private var waiters: [Waiter] = []
  private struct Waiter {
    let asked: Int
    var remaining: [String: Lane]
    var received = true
    let answer = Promise<Bool>()
  }
  private var prepared = false
  private var preparing: Task<Bool, Never>?
  private var busy = false
  private let generation: SyncGeneration
  private var stopped: Bool { generation.isOver }

  init(
    uploader: any RecordUploader, coordinator: SyncCoordinator, generation: SyncGeneration = SyncGeneration(),
    prepare: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.uploader = uploader
    self.coordinator = coordinator
    self.generation = generation
    self.prepare = prepare
  }

  func start() async {
    let changes = await coordinator.store.syncChanges()  // 先订阅：返回后的提交都不会漏
    guard !stopped else { return }  // 订阅期间停下了
    let due = coordinator.retryDue.stream()
    tasks = [
      Task { for await change in changes { self.changed(change) } },
      Task { for await _ in due { await self.resume() } },
    ]
    kick()  // 上一次没传完的照常发：没人在等，照常退避
  }

  func stop() async {
    generation.end()
    let running = tasks + Array(expresses.values) + lanes.values.flatMap { [$0.running, $0.gathering].compactMap(\.self) }
    let preparation = preparing
    tasks = []
    preparation?.cancel()
    running.forEach { $0.cancel() }
    for task in running { await task.value }
    _ = await preparation?.value
  }

  /// 不等；守着重试的时刻。
  func kick() {
    for lane in Lane.allCases { trigger(lane) }
  }

  /// 现在发一轮并等它结束：越过连不上与被拒的等待试一次，服务器要求的等待照守。
  /// 挂住的请求至多到 CloudKit 的超时（`RequestLimits.request`），在系统给的后台时间之内。
  func flush() async {
    for lane in Lane.allCases { trigger(lane, urgent: true) }
    let express = Array(expresses.values)
    for lane in Lane.allCases { await lanes[lane]?.running?.value }
    for task in express { await task.value }
  }

  /// 马上传这几条：不进攒批窗口，等到它们都有了结果（全收下为 true；离线等没传成的为 false，之后照常重试；已不是待推送的当场 true）。
  /// 收下指服务器收下的不早于此刻库里的这一版。
  /// 调用方被取消也不提前返回（`cancellable: false`，等的是多方共用的那次上传），最长到 CloudKit 的请求超时：不要在任务组里拿它跟到点比快，
  /// 输的一方等不了，组返回不了。要设时限就用 `abandonable` 包住它，或照 `DiagnosticOutbox.reconcile(within:)`：事件流加一个定时 Task，谁先 yield 谁赢。
  func send(_ names: Set<String>) async -> Bool {
    guard !names.isEmpty else { return true }
    guard !stopped else { return false }
    var remaining: [String: Lane] = [:]
    do {
      for lane in Lane.allCases {
        let pending = try await coordinator.store.pendingSync(among: names, in: lane.tables)
        for name in pending.saves.map(\.id) + pending.deletes { remaining[name] = lane }
      }
    } catch { return false }
    guard !remaining.isEmpty else { return true }  // 读在要之后：要的那一版服务器已有
    guard !stopped else { return false }
    asks += 1
    let waiter = Waiter(asked: asks, remaining: remaining)
    waiters.append(waiter)
    for lane in Set(waiter.remaining.values) { express(lane) }
    return (try? await generation.value(of: waiter.answer, cancellable: false)) ?? false
  }

  /// 只改同步元数据的提交（碰了 `syncRecords`）说不清是哪条通道的，两条都叫。
  private func changed(_ change: SyncChange) {
    for lane in Lane.allCases where change.tables.contains(.syncRecords) || !change.tables.isDisjoint(with: lane.tables) {
      if change.urgent, lane == .live { express(lane) } else { trigger(lane, gather: true) }
    }
  }

  /// 有话在等先只发实时通道，跑完再发后台：断网时每次重试只一个请求。
  private func resume() async {
    trigger(.live)
    await lanes[.live]?.running?.value
    trigger(.bulk)
  }

  /// 叫这条通道跑一轮（`gather`：等攒批窗口），挑全部待推送；`urgent`（`flush`）越过连不上与被拒的等待。
  private func trigger(_ lane: Lane, gather: Bool = false, urgent: Bool = false) {
    guard !stopped, var state = lanes[lane] else { return }
    defer { lanes[lane] = state }
    if urgent { state.urgent = true }
    if state.running != nil {
      state.again = true
    } else if !gather {
      state.gathering?.cancel()
      state.gathering = nil
      state.running = run(lane)
    } else if state.gathering == nil {
      state.gathering = Task {
        try? await Task.sleep(for: Self.gatherWindow)
        guard !Task.isCancelled else { return }
        self.gathered(lane)
      }
    }
  }

  private func gathered(_ lane: Lane) {
    lanes[lane]?.gathering = nil
    trigger(lane)
  }

  private func run(_ lane: Lane) -> Task<Void, Never> {
    Task {
      repeat {
        lanes[lane]?.again = false
        await round(lane)
      } while lanes[lane]?.again == true && !stopped
      lanes[lane]?.running = nil
    }
  }

  private func round(_ lane: Lane) async {
    let urgent = lanes[lane]?.urgent == true
    lanes[lane]?.urgent = false
    for _ in 0..<Self.batchesPerRound {
      guard await sendBatch(lane, urgent: urgent) else { return }
    }
    lanes[lane]?.again = true  // 一轮的批数用完，还有没发完的
  }

  /// 要马上传的（这次运行里刚写下的、`send` 在等的）：不等攒批窗口、不等这一轮在路上的那批，另发一批（`express`），
  /// 只挑一写下就该传的版本与在等的，越过连不上与被拒的等待；其余的（领取、会话进展这些不急的版本，装不下的）照常等窗口，有人在等就接着发。
  private func express(_ lane: Lane) {
    guard !stopped else { return }
    let id = nextExpress
    nextExpress += 1
    expresses[id] = Task {
      _ = await sendBatch(lane, urgent: true, urgentOnly: true)
      expresses[id] = nil
      trigger(lane, gather: !waiters.contains { $0.remaining.values.contains(lane) })
    }
  }

  /// 挑一批、发；返回能不能接着发下一批。
  private func sendBatch(_ lane: Lane, urgent asked: Bool, urgentOnly: Bool = false) async -> Bool {
    let wanted = Set(waiters.flatMap { $0.remaining.filter { $0.value == lane }.keys })
    let readAt = asks
    // 发不了（被等待挡下、停下了、读库出错，协调器已记下）：在等的答没传成，下一次触发再来
    guard !stopped, await coordinator.admits(.upload(urgent: asked || !wanted.isEmpty)), await coordinator.canSync, await ready(),
      var batch = try? await coordinator.nextBatch(
        lane, limit: lanes[lane]?.limit ?? lane.limit, urgentOnly: urgentOnly, wanted: wanted, excluding: lanes[lane]?.inFlight ?? [])
    else {
      answer(lane, readAt: readAt) { _ in false }
      return false
    }
    // 挑的期间另一批占下的留给那一批：同一条记录同一时刻只一版在路上
    let taken = batch.names.intersection(lanes[lane]?.inFlight ?? [])
    batch.drop(taken)
    batch.left.formUnion(taken)
    // 已不是待推送的（别的批已收下、删掉了）答收下，这一版传不上去的答没传成，装不下与在路上的接着等
    answer(lane, readAt: readAt) { batch.names.contains($0) || batch.left.contains($0) ? nil : !batch.stuck.contains($0) }
    guard !batch.isEmpty else { return false }
    guard await upload(lane, batch, readAt: readAt) else {
      let inFlight = lanes[lane]?.inFlight ?? []
      answer(lane, readAt: readAt) { batch.left.contains($0) && !inFlight.contains($0) ? false : nil }
      return false
    }
    return true
  }

  /// 发一批；返回能不能接着发下一批。`readAt`：这一批读库之前的 `asks`。
  private func upload(_ lane: Lane, _ prepared: OutgoingBatch, readAt: Int) async -> Bool {
    lanes[lane]?.inFlight.formUnion(prepared.names)
    await updateBusy()
    let next = await outcome(lane, prepared, readAt: readAt)
    lanes[lane]?.inFlight.subtract(prepared.names)
    await updateBusy()
    return next
  }

  private func outcome(_ lane: Lane, _ prepared: OutgoingBatch, readAt: Int) async -> Bool {
    var names = prepared.names
    do {
      let (batch, _) = try await coordinator.reserveForUpload(prepared)  // 作废的仍有人等，下一批读库时答
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
      let received = Set(sent.saved.map(\.recordID.recordName) + sent.deleted.map(\.recordName))
      answer(lane, readAt: readAt) { names.contains($0) ? received.contains($0) : nil }
      if received.count == names.count { regrow(lane) } else { lanes[lane]?.acceptedInARow = 0 }
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
    } catch let error as CKError where error.code == .limitExceeded && (lanes[lane]?.limit ?? 1) > 1 {
      lanes[lane]?.limit /= 2  // 这一批太大：减半再试
      lanes[lane]?.acceptedInARow = 0
      answer(lane, readAt: readAt) { names.contains($0) ? false : nil }
      return true
    } catch {
      answer(lane, readAt: readAt) { names.contains($0) ? false : nil }
      if stopped { return false }  // 停下时被取消的请求不是同步的失败，不记
      if let error = error as? CKError, error.code == .userDeletedZone {
        await coordinator.zoneMissing(deletedByUser: true)
        return false
      }
      await schedule(await coordinator.failed(error))
      return false
    }
  }

  private func regrow(_ lane: Lane) {
    guard var state = lanes[lane], state.limit < lane.limit else { return }
    state.acceptedInARow += 1
    if state.acceptedInARow >= Self.regrowAfter {
      state.limit = min(state.limit * 2, lane.limit)
      state.acceptedInARow = 0
    }
    lanes[lane] = state
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
    await coordinator.hold(fault, waiting: !waiters.isEmpty)
  }

  private func updateBusy() async {
    let now = lanes.values.contains { !$0.inFlight.isEmpty }
    guard now != busy else { return }
    busy = now
    await coordinator.setSending(now)
  }

  /// 读库在 `readAt` 之后才要的不答；`verdict` 对这条通道里在等的每一条给出收下（true）、没传成（false）或接着等（nil）。
  private func answer(_ lane: Lane, readAt: Int, _ verdict: (String) -> Bool?) {
    var rest: [Waiter] = []
    for var waiter in waiters {
      if waiter.asked <= readAt {
        for (name, at) in waiter.remaining where at == lane {
          guard let received = verdict(name) else { continue }
          waiter.received = waiter.received && received
          waiter.remaining[name] = nil
        }
      }
      if waiter.remaining.isEmpty { waiter.answer.resolve(.success(waiter.received)) } else { rest.append(waiter) }
    }
    waiters = rest
  }
}

extension OutgoingBatch {
  var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }

  /// 作废的去掉后，这批就不再是"全部"。
  mutating func drop(_ names: Set<String>) {
    guard !names.isDisjoint(with: self.names) else { return }
    saves.removeAll { names.contains($0.recordID.recordName) }
    deletes.removeAll { names.contains($0.recordName) }
    drains = nil
  }
}
