import CloudKit
import CueStore
import Foundation
import os

/// 文件那一路的推：待推送的附件记录（带文件）不进后台那一路的批，在这里一条一个上传、至多 `parallel` 条同时在路上，带进度（`TransferBoard`）。
/// 大文件传几十秒，同一刻写下的别的记录不跟着等（`sync-bench.py files` 量的就是这个）。
///
/// 上传是长期操作（`FileCloud.uploadFile`）：App 退出后系统接着传，下次开始时先接上（`resume`），接上的那几条不再另传。
/// 结果与后台那一路一样交给协调器记账（`SyncCoordinator.sent`），服务器收下了就删本机的保底（`AttachmentFiles.uploaded`）。
/// 重试守同步层唯一的调度（`SyncCoordinator.admits(.fileUpload)`、`hold`，等待结束时 `retryDue` 接着传），空间不足的停顿也在那里（`holdFiles`）。
/// 在路上的只记在协调器（`SyncCoordinator.fileUploads`）。
///
/// 属于一代（`SyncGeneration`）。`stop` 之后不再开始新的上传、不再补位；在途的上传不取消（交给系统的长期操作，退出后系统接着传完），
/// 但本代不再等它：放回（`fileDone`）、清进度、结果到了也不记账，`stop` 返回时本代在协调器里什么都不留。这几条仍是待推送，由下一代重传。
/// 理由：换账号后处理（`CloudSync.resolve`）时，旧账号那次上传的结果若照常记账，会被记成新账号已收下，新账号就永远收不到这个文件
/// （协调器那时已重新开始，`sent` 分不出结果属于哪个账号）。代价：同一条可能被新旧两次上传先后送到同一个账号，后到的那次以版本冲突被拒，
/// 协调器带上服务器版本后不再重传（替身测过这条路径；真实 CloudKit 里长期操作被放手后的落账未验证）。
/// 否决的做法：旧结果照常记账、靠停下的协调器拒收——`resolve` 在旧结果回来之前就让协调器重新开始了，拒收不成立。
actor FileSender {
  static let parallel = 2
  private static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  private let cloud: any FileCloud & RecordUploader
  private let coordinator: SyncCoordinator
  private let board: TransferBoard
  /// 对过最低对端版本（`RecordSender.ready`）：文件同别的记录一样在那之后才传。
  private let ready: @Sendable () async -> Bool
  private let generation: SyncGeneration
  private var stopped: Bool { generation.isOver }
  /// 跟随提交与重试时刻的任务。
  private var tasks: [Task<Void, Never>] = []
  /// 本代交出去的每一趟上传（等结果、记账）：`stop` 等它们放手。
  private var uploads: [UUID: Task<Void, Never>] = [:]
  /// 补位同一时刻只有一趟在跑；跑的时候又被叫到记成再补一趟（两趟交错会各自按同一个在路上的数多取）。
  private var filling = false
  private var refill = false

  init(
    cloud: any FileCloud & RecordUploader, coordinator: SyncCoordinator, board: TransferBoard, generation: SyncGeneration = SyncGeneration(),
    ready: @escaping @Sendable () async -> Bool
  ) {
    self.cloud = cloud
    self.coordinator = coordinator
    self.board = board
    self.generation = generation
    self.ready = ready
  }

  /// 接上上次没交回结果的，再跟随本机提交与重试的等待结束开始传。
  func start() async {
    let changes = await coordinator.store.syncChanges()  // 先订阅：返回后的提交都不会漏
    guard !stopped else { return }  // 订阅期间停下了
    let due = coordinator.retryDue.stream()
    tasks = [
      Task { for await tables in changes where tables.contains(.attachments) { await self.fill() } },
      Task { for await _ in due { await self.fill() } },
    ]
    await resume()
    await fill()
  }

  /// 不再开始新的上传，等跟随的任务收尾、等每一趟上传放手（见类型注释）；在路上的上传本身不取消（退出时系统接着传完，下次 `resume`）。
  func stop() async {
    generation.end()
    let running = tasks + Array(uploads.values)
    tasks = []
    running.forEach { $0.cancel() }
    for task in running { await task.value }
  }

  /// 交出一趟上传：登记着，`stop` 等它放手。排上去到真正跑之间停下了的不开始。
  private func send(_ records: [CKRecord], _ upload: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> SentRecords) {
    let id = UUID()
    uploads[id] = Task {
      defer { uploads[id] = nil }
      guard !stopped else { return await release(records) }
      await finish(records, upload)
    }
  }

  private func resume() async {
    guard !stopped else { return }
    do {
      for upload in try await cloud.resumedFileUploads() {
        let records = upload.records
        await coordinator.filesResumed(records.map(\.recordID.recordName))
        Self.log.notice("接上上次没交回结果的文件上传：\(records.count, privacy: .public) 条")
        send(records) { progress in try await upload.result(progress) }
      }
    } catch {
      // 接不上的那几条仍是待推送，照常再传一遍；连不上的由下一次传归类
      Self.log.notice("没能列出上次的文件上传：\(error.brief, privacy: .public)")
    }
  }

  /// 补足在路上的：守重试的时刻与空间不足的停顿，先对过门槛。
  private func fill() async {
    if filling {
      refill = true
      return
    }
    filling = true
    defer { filling = false }
    repeat {
      refill = false
      await fillOnce()
    } while refill && !stopped
  }

  private func fillOnce() async {
    guard !stopped, await coordinator.fileUploads.count < Self.parallel, await coordinator.admits(.fileUpload), await coordinator.canSync, await ready()
    else { return }
    let pending: [String]
    do { pending = try await coordinator.store.pendingAttachments() } catch {
      await coordinator.failed(error)
      return
    }
    for name in pending {
      guard !stopped, await coordinator.fileUploads.count < Self.parallel else { return }
      let taken: CKRecord?
      do { taken = try await coordinator.takeFile(name) } catch { return }  // 停下了或读库出错：协调器已记下，下一次触发再来
      guard let record = taken else { continue }  // 已在路上，或这一版传不上去
      guard !stopped else { return await release([record]) }  // 读库时停下了：放回，不开始
      send([record]) { [cloud] progress in try await cloud.uploadFile(record, progress: progress) }
    }
  }

  /// 等一个上传的结果、记账，再补下一个。本代结束了就放手：不再等、结果不记账（见类型注释）。
  private func finish(_ records: [CKRecord], _ upload: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> SentRecords) async {
    let keys = records.compactMap { RecordMapper.row(from: $0)?.attachmentKey }
    let board = board, generation = generation
    for key in keys { board.set(key, .upload, 0) }
    let job = Task { try await upload { fraction in if !generation.isOver { keys.forEach { board.set($0, .upload, fraction) } } } }
    do {
      var sent = try await generation.outcome(of: job)
      guard !stopped else { return await release(records) }
      let full = sent.failedSaves.filter { SyncFault($0.error) == .account(.quotaExceeded) }
      sent.failedSaves.removeAll { SyncFault($0.error) == .account(.quotaExceeded) }
      if let first = full.first { await coordinator.holdFiles(first.error) }
      let outcome = await coordinator.sent(sent, for: OutgoingBatch(saves: records, deletes: []))
      guard !outcome.paused else { return await release(records) }
      for record in sent.saved {
        // 删不掉的保底只多占一个硬链接，下次收下同一个文件时再删
        do { try await coordinator.store.attachmentUploaded(record.recordID.recordName) } catch {
          Self.log.error("附件的保底没能删：\(error.brief, privacy: .public)")
        }
      }
      if !sent.saved.isEmpty { await coordinator.filesAccepted() }
      if outcome.zoneMissing { try? await cloud.saveZone() }
      if let fault = outcome.fault { await coordinator.hold(fault, waiting: false) } else if !sent.saved.isEmpty { await coordinator.progressed() }
    } catch where stopped {
      return await release(records)
    } catch {
      await failed(error)
    }
    await release(records)
    await fill()
  }

  /// 这一趟结束（或本代放手）：清进度、放回协调器（`fileDone`）。
  private func release(_ records: [CKRecord]) async {
    for record in records {
      if let key = RecordMapper.row(from: record)?.attachmentKey { board.clear(key) }
      await coordinator.fileDone(record.recordID.recordName)
    }
  }

  private func failed(_ error: any Error) async {
    if SyncFault(error) == .account(.quotaExceeded) { return await coordinator.holdFiles(error) }
    if let error = error as? CKError, error.code == .zoneNotFound {
      try? await cloud.saveZone()  // 新装的第一次就是文件：建区，下一次触发再传
      return
    }
    await coordinator.hold(await coordinator.failed(error), waiting: false)
  }
}
