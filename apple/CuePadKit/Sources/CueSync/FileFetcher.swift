import CloudKit
import CueStore
import Foundation

/// 文件那一路的取：附件记录随拉取与别的记录一起先入库（不带文件，`ZonePuller`），文件在这里另取、带进度（`TransferBoard`），
/// 验过哈希才放进附件目录（`AttachmentFiles.adopt`）。记录在不等于文件在本机：本机有没有只看附件目录。
///
/// 自动取（`wanted`）：Mac 取全部；手机只取不大于 `phoneAutoLimit`、且网络不按流量计费（`NetworkReturns.isMetered`）时的，其余用到时取（`fetch`）。
/// 自己传上去的文件本来就在本机，不会再取。自动取的至多 `parallel` 个同时在路上；用到时取的不排队。
/// 跟着附件表（新记录到了）、网络回来（手机换到 Wi-Fi）与重试的等待结束再看一遍；连不上与服务器要求等的守同步层的调度（拉取那一档，`admits(.pull)`）。
/// 文件坏了（没有文件、哈希不符）报告一次、记下不再取：它不会自己变好。
actor FileFetcher {
  static let parallel = 2
  static let phoneAutoLimit = 10 << 20

  private let cloud: any FileCloud
  private let coordinator: SyncCoordinator
  private let board: TransferBoard
  private var files: AttachmentFiles { coordinator.store.files }
  /// 库里的附件记录（按 key）：订阅附件表得到。
  private var known: [String: Attachment] = [:]
  private var running: [String: Task<URL, any Error>] = [:]
  /// 在跑的里面自动取的（占 `parallel` 的名额）。
  private var automatic: Set<String> = []
  private var damaged: Set<String> = []
  /// 用到时要取、记录还没到的：记录到了就取。
  private var waiters: [UUID: (key: String, continuation: CheckedContinuation<Attachment, any Error>)] = [:]
  private var tasks: [Task<Void, Never>] = []

  init(cloud: any FileCloud, coordinator: SyncCoordinator, board: TransferBoard) {
    self.cloud = cloud
    self.coordinator = coordinator
    self.board = board
  }

  func start() {
    let rows = coordinator.store.observe { try $0.attachments() }
    let network = NetworkReturns.stream(), due = coordinator.retryDue.stream()
    tasks = [
      Task {
        do {
          for try await rows in rows { await self.seen(rows) }
        } catch {
          await self.coordinator.failed(error)
        }
      },
      Task { for await _ in network { await self.scan() } },
      Task { for await _ in due { await self.scan() } },
    ]
  }

  func stop() {
    tasks.forEach { $0.cancel() }
    tasks = []
    running.values.forEach { $0.cancel() }
    for waiter in waiters.values { waiter.continuation.resume(throwing: FileFetchFailure.notSyncing) }
    waiters = [:]
  }

  /// 这个文件在本机的位置：本机没有就现在取（不看自动取的条件），记录还没到就等它到。被取消就抛出。
  func fetch(_ key: String) async throws -> URL {
    if let url = files.fileURL(forKey: key) { return url }
    guard !damaged.contains(key) else { throw FileFetchFailure.damaged }
    if let task = running[key] { return try await task.value }
    let attachment: Attachment
    if let found = known[key] { attachment = found } else { attachment = try await record(of: key) }
    if let url = files.fileURL(forKey: key) { return url }
    return try await (running[key] ?? begin(attachment, automatic: false)).value
  }

  /// 等这个 key 的附件记录到本机库。
  private func record(of key: String) async throws -> Attachment {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
        waiters[id] = (key, continuation)
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }

  private func seen(_ rows: [Attachment]) async {
    known = Dictionary(rows.map { (AttachmentFiles.key(of: $0), $0) }, uniquingKeysWith: { first, _ in first })
    for (id, waiter) in waiters {
      guard let attachment = known[waiter.key] else { continue }
      waiters[id] = nil
      waiter.continuation.resume(returning: attachment)
    }
    await scan()
  }

  /// 补足自动取的。
  private func scan() async {
    guard automatic.count < Self.parallel, await coordinator.canSync, await coordinator.admits(.pull) else { return }
    for (key, attachment) in known where automatic.count < Self.parallel {
      guard running[key] == nil, !damaged.contains(key), Self.wanted(attachment), files.fileURL(forKey: key) == nil else { continue }
      begin(attachment, automatic: true)
    }
  }

  /// 不用你点就取：Mac 全取；手机只取小的、且不在按流量计费的网络上。
  private static func wanted(_ attachment: Attachment) -> Bool {
    #if os(macOS)
    true
    #else
    attachment.byteCount <= phoneAutoLimit && !NetworkReturns.isMetered
    #endif
  }

  @discardableResult
  private func begin(_ attachment: Attachment, automatic isAutomatic: Bool) -> Task<URL, any Error> {
    let key = AttachmentFiles.key(of: attachment)
    let task = Task { try await self.download(attachment, key) }
    running[key] = task
    if isAutomatic { automatic.insert(key) }
    Task {
      _ = await task.result
      self.ended(key)
      await self.scan()
    }
    return task
  }

  private func ended(_ key: String) {
    running[key] = nil
    automatic.remove(key)
    board.clear(key)
  }

  private func download(_ attachment: Attachment, _ key: String) async throws -> URL {
    let board = board, name = attachment.id.uuidString.lowercased()
    board.set(key, .download, 0)
    do {
      let record = try await cloud.downloadFile(coordinator.recordID(name)) { board.set(key, .download, $0) }
      guard let record else { throw CKError(.unknownItem) }  // 这期间被删了：删除随下一拉到
      guard let file = (record[RecordMapper.fileKey] as? CKAsset)?.fileURL else {
        throw await broken(name, detail: String(localized: "附件记录没有文件"), key)
      }
      do {
        try files.adopt(fileAt: file, key: key)
      } catch let error as CueStoreError where [.invalidAttachmentHash, .attachmentHashMismatch].contains(error) {
        throw await broken(name, detail: "\(error)", key)
      }
      guard let url = files.fileURL(forKey: key) else { throw CueStoreError.notFound }
      return url
    } catch let error as FileFetchFailure {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as CKError where error.code == .unknownItem {
      throw error
    } catch {
      let fault = await coordinator.failed(error)
      if fault.isWait || fault.retryAfter != nil { await coordinator.hold(fault, waiting: false) }
      throw error
    }
  }

  private func broken(_ name: String, detail: String, _ key: String) async -> FileFetchFailure {
    damaged.insert(key)
    await coordinator.report(.damaged, detail: detail, kind: .incoming, recordType: Table.attachments.rawValue, recordName: name)
    return .damaged
  }
}
