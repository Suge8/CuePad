import CloudKit
import CueStore
import CueText
import Foundation
import Synchronization

/// 文件那一路的取：附件记录随拉取与别的记录一起先入库（不带文件，`ZonePuller`），文件在这里另取、带进度（`TransferBoard`），
/// 验过哈希才放进附件目录（`AttachmentFiles.adopt`）。记录在不等于文件在本机：本机有没有只看附件目录。
///
/// 自动取（`wanted`）：Mac 取全部；手机只取不大于 `phoneAutoLimit`、且网络不按流量计费（`NetworkReturns.isMetered`）时的，其余用到时取（`fetch`）。
/// 自己传上去的文件本来就在本机，不会再取。自动取的至多 `parallel` 个同时在路上；用到时取的不排队。
/// 跟着附件表（新记录到了）、网络回来（手机换到 Wi-Fi）与重试的等待结束再看一遍。失败交给同步层唯一的调度（`SyncCoordinator.hold`），
/// 自动取守它（`admits(.fileDownload(urgent: false))`），等待结束（`retryDue`）再试；用到时取的同马上传，只越过连不上与被拒的退避。
/// 文件坏了（没有文件、哈希不符）报告一次，与这期间在 iCloud 被删了的一样记下不再取（`skipped`），直到记录本身变了或没了。
/// 用到时取的调用方被取消就当场抛出；没有别人在等、也不是自动取的那一趟随之取消。
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
  /// 不再取的（坏了：`FileFetchFailure.damaged`；在 iCloud 被删了：`unknownItem`）与那时的记录：用到时取的照样抛出这个错，
  /// 记录变了（另一台重传）或没了（删除拉到了）就忘掉。
  private var skipped: [String: (attachment: Attachment, error: any Error)] = [:]
  /// 每个 key 有几个用到时取的调用方在等。
  private var demand: [String: Int] = [:]
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

  /// 这个文件在本机的位置：本机没有就现在取（不看自动取的条件），记录还没到就等它到，服务器要求等就等到点。
  /// 停下同步（要你决定、要更新、没有账号）抛 `FileFetchFailure.notSyncing`；被取消就抛出。
  func fetch(_ key: String) async throws -> URL {
    if let url = files.fileURL(for: key) { return url }
    if let skip = skipped[key] { throw skip.error }
    demand[key, default: 0] += 1
    defer { release(key) }
    if let task = running[key] { return try await outcome(of: task) }
    try await admitted()
    let attachment: Attachment
    if let found = known[key] { attachment = found } else { attachment = try await record(of: key) }
    try await admitted()  // 等记录的时候可能停下了、或被要求等
    if let url = files.fileURL(for: key) { return url }
    return try await outcome(of: running[key] ?? begin(attachment, automatic: false))
  }

  /// 同步层此刻许这一路发请求：停下了抛出，服务器要求等就等到等待结束（`retryDue`）。
  private func admitted() async throws {
    let due = coordinator.retryDue.stream()  // 先订阅：看条件时跨了 actor，其间结束的那次不漏
    while true {
      guard await coordinator.canSync else { throw FileFetchFailure.notSyncing }
      if await coordinator.admits(.fileDownload(urgent: true)) { return }
      for await _ in due { break }
      try Task.checkCancellation()
    }
  }

  /// 等这一趟的结果；调用方被取消就当场抛出，不等下载结束。
  private func outcome(of task: Task<URL, any Error>) async throws -> URL {
    let once = Once()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        once.set(continuation)
        Task { once.resume(with: await task.result) }
        if Task.isCancelled { once.resume(with: .failure(CancellationError())) }
      }
    } onCancel: {
      once.resume(with: .failure(CancellationError()))
    }
  }

  /// 一个用到时取的调用方不等了：没人在等、也不是自动取的那一趟随之取消。
  private func release(_ key: String) {
    let left = (demand[key] ?? 1) - 1
    demand[key] = left > 0 ? left : nil
    if left <= 0, !automatic.contains(key) { running[key]?.cancel() }
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
    known = Dictionary(rows.map { (AttachmentKey.make(hash: $0.hash, format: $0.format), $0) }, uniquingKeysWith: { first, _ in first })
    skipped = skipped.filter { known[$0.key] == $0.value.attachment }
    for (id, waiter) in waiters {
      guard let attachment = known[waiter.key] else { continue }
      waiters[id] = nil
      waiter.continuation.resume(returning: attachment)
    }
    await scan()
  }

  /// 补足自动取的。
  private func scan() async {
    guard automatic.count < Self.parallel, await coordinator.canSync, await coordinator.admits(.fileDownload(urgent: false)) else { return }
    for (key, attachment) in known where automatic.count < Self.parallel {
      guard running[key] == nil, skipped[key] == nil, Self.wanted(attachment), files.fileURL(for: key) == nil else { continue }
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
    let key = AttachmentKey.make(hash: attachment.hash, format: attachment.format)
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
      guard let record else { throw skip(attachment, key, CKError(.unknownItem)) }  // 这期间被删了：删除随下一拉到
      guard let file = (record[RecordMapper.fileKey] as? CKAsset)?.fileURL else {
        throw await broken(attachment, key, detail: String(localized: "附件记录没有文件"))
      }
      do {
        try files.adopt(fileAt: file, key: key)
      } catch let error as CueStoreError where [.invalidAttachmentHash, .attachmentHashMismatch].contains(error) {
        throw await broken(attachment, key, detail: "\(error)")
      }
      guard let url = files.fileURL(for: key) else { throw CueStoreError.notFound }
      return url
    } catch where skipped[key] != nil {
      throw error
    } catch where Task.isCancelled || error is CancellationError {
      throw CancellationError()  // 用到时取的调用方不等了：CloudKit 报的取消不归类、不让同步等
    } catch {
      await coordinator.hold(await coordinator.failed(error), waiting: false)
      throw error
    }
  }

  private func skip(_ attachment: Attachment, _ key: String, _ error: any Error) -> any Error {
    skipped[key] = (attachment, error)
    return error
  }

  private func broken(_ attachment: Attachment, _ key: String, detail: String) async -> any Error {
    let name = attachment.id.uuidString.lowercased()
    await coordinator.report(.damaged, detail: detail, kind: .incoming, recordType: Table.attachments.rawValue, recordName: name)
    return skip(attachment, key, FileFetchFailure.damaged)
  }
}

/// 一个续体只答一次：结果与取消谁先到算谁。
private final class Once: Sendable {
  private let waiting = Mutex<CheckedContinuation<URL, any Error>?>(nil)

  func set(_ continuation: CheckedContinuation<URL, any Error>) { waiting.withLock { $0 = continuation } }

  func resume(with result: Result<URL, any Error>) { waiting.withLock { $0.take() }?.resume(with: result) }
}
