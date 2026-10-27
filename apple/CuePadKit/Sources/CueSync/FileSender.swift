import CloudKit
import CueStore
import Foundation
import os

/// 文件那一路的推：待推送的附件记录（带文件）不进后台那一路的批，在这里一条一个上传、至多 `parallel` 条同时在路上，带进度（`TransferBoard`）。
/// 大文件传几十秒，同一刻写下的别的记录不跟着等（`sync-bench.py files` 量的就是这个）。
///
/// 上传是长期操作（`FileCloud.uploadFile`）：App 退出后系统接着传，下次开始时先接上（`resume`），接上的那几条不再另传。
/// 结果与后台那一路一样交给协调器记账（`SyncCoordinator.sent`），服务器收下了就删本机的保底（`AttachmentFiles.uploaded`）。
/// 重试守同步层唯一的调度（`SyncCoordinator.admits`、`hold`，等待结束时 `retryDue` 接着传），只有 iCloud 空间不足是这一路自己的：
/// 文件停在本机、`quotaPause` 后再试，期间别的记录照常同步（`SyncState.filesOverQuota`，不改 `status`）。
actor FileSender {
  static let parallel = 2
  static let quotaPause = Duration.seconds(600)
  private static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  private let cloud: any FileCloud & RecordUploader
  private let coordinator: SyncCoordinator
  private let board: TransferBoard
  /// 对过最低对端版本（`RecordSender.ready`）：文件同别的记录一样在那之后才传。
  private let ready: @Sendable () async -> Bool
  private var running: Set<String> = []
  private var quotaUntil: ContinuousClock.Instant?
  private var tasks: [Task<Void, Never>] = []

  init(cloud: any FileCloud & RecordUploader, coordinator: SyncCoordinator, board: TransferBoard, ready: @escaping @Sendable () async -> Bool) {
    self.cloud = cloud
    self.coordinator = coordinator
    self.board = board
    self.ready = ready
  }

  /// 接上上次没交回结果的，再跟随本机提交与重试的等待结束开始传。
  func start() async {
    let changes = await coordinator.store.syncChanges()  // 先订阅：返回后的提交都不会漏
    let due = coordinator.retryDue.stream()
    tasks = [
      Task { for await tables in changes where tables.contains(.attachments) { await self.fill() } },
      Task { for await _ in due { await self.fill() } },
    ]
    await resume()
    await fill()
  }

  /// 不再开始新的上传；在路上的不取消（退出时系统接着传完，下次 `resume`）。
  func stop() {
    tasks.forEach { $0.cancel() }
    tasks = []
  }

  private func resume() async {
    do {
      for upload in try await cloud.resumedFileUploads() {
        let records = upload.records, names = records.map(\.recordID.recordName)
        running.formUnion(names)
        await coordinator.filesResumed(names)
        Self.log.notice("接上上次没交回结果的文件上传：\(records.count, privacy: .public) 条")
        Task {
          await self.finish(records) { progress in try await upload.result(progress) }
        }
      }
    } catch {
      // 接不上的那几条仍是待推送，照常再传一遍；连不上的由下一次传归类
      Self.log.notice("没能列出上次的文件上传：\(error.brief, privacy: .public)")
    }
  }

  /// 补足在路上的：守重试的时刻与空间不足的停顿，先对过门槛。
  private func fill() async {
    guard running.count < Self.parallel, quotaUntil.map({ ContinuousClock.now >= $0 }) ?? true else { return }
    guard await coordinator.admits(.upload(urgent: false)), await coordinator.canSync, await ready() else { return }
    let pending: [String]
    do { pending = try await coordinator.store.pendingAttachments() } catch {
      await coordinator.failed(error)
      return
    }
    for name in pending where running.count < Self.parallel && !running.contains(name) {
      let taken: CKRecord?
      do { taken = try await coordinator.takeFile(name) } catch { return }  // 停下了或读库出错：协调器已记下，下一次触发再来
      guard let record = taken else { continue }
      running.insert(name)
      Task { await self.finish([record]) { progress in try await self.cloud.uploadFile(record, progress: progress) } }
    }
  }

  /// 等一个上传的结果、记账，再补下一个。
  private func finish(_ records: [CKRecord], _ upload: (@escaping @Sendable (Double) -> Void) async throws -> SentRecords) async {
    let keys = records.compactMap { RecordMapper.row(from: $0)?.attachmentKey }
    let board = board
    for key in keys { board.set(key, .upload, 0) }
    do {
      var sent = try await upload { fraction in keys.forEach { board.set($0, .upload, fraction) } }
      let full = sent.failedSaves.filter { SyncFault($0.error) == .account(.quotaExceeded) }
      sent.failedSaves.removeAll { SyncFault($0.error) == .account(.quotaExceeded) }
      if !full.isEmpty { await overQuota(full[0].error) }
      let outcome = await coordinator.sent(sent, for: OutgoingBatch(saves: records, deletes: []))
      for record in sent.saved {
        if let key = RecordMapper.row(from: record)?.attachmentKey { coordinator.store.files.uploaded(key) }
      }
      if !sent.saved.isEmpty, quotaUntil != nil {
        quotaUntil = nil
        await coordinator.setFilesOverQuota(false)
      }
      if outcome.zoneMissing { try? await cloud.saveZone() }
      if let fault = outcome.fault { await coordinator.hold(fault, waiting: false) } else if !sent.saved.isEmpty { await coordinator.progressed() }
    } catch {
      await failed(error)
    }
    for key in keys { board.clear(key) }
    for record in records {
      running.remove(record.recordID.recordName)
      await coordinator.fileDone(record.recordID.recordName)
    }
    await fill()
  }

  private func failed(_ error: any Error) async {
    if SyncFault(error) == .account(.quotaExceeded) { return await overQuota(error) }
    if let error = error as? CKError, error.code == .zoneNotFound {
      try? await cloud.saveZone()  // 新装的第一次就是文件：建区，下一次触发再传
      return
    }
    await coordinator.hold(await coordinator.failed(error), waiting: false)
  }

  /// 空间不足：这一路停 `quotaPause`，到点再试；别的记录照常。
  private func overQuota(_ error: any Error) async {
    if quotaUntil == nil { Self.log.notice("iCloud 空间不足，文件先不上传：\(error.brief, privacy: .public)") }
    let until = ContinuousClock.now + Self.quotaPause
    quotaUntil = until
    await coordinator.setFilesOverQuota(true)
    tasks.append(Task {
      try? await Task.sleep(until: until, clock: .continuous)
      guard !Task.isCancelled else { return }
      await self.fill()
    })
  }
}
