import CloudKit
import CueStore
import Foundation

actor FileFetcher {
  static let parallel = 2
  static let phoneAutoLimit = 10 << 20

  private let cloud: any FileCloud
  private let coordinator: SyncCoordinator
  private let board: TransferBoard
  private var files: AttachmentFiles { coordinator.store.files }
  private var known: [String: Attachment] = [:]
  private var running: [String: Task<URL, any Error>] = [:]
  private var automatic: Set<String> = []
  private var skipped: [String: (attachment: Attachment, error: any Error)] = [:]
  private var demand: [String: Int] = [:]
  private var waiters: [(key: String, answer: Promise<Attachment>)] = []
  private var tasks: [Task<Void, Never>] = []
  private let generation: SyncGeneration

  init(cloud: any FileCloud, coordinator: SyncCoordinator, board: TransferBoard, generation: SyncGeneration = SyncGeneration()) {
    self.cloud = cloud
    self.coordinator = coordinator
    self.board = board
    self.generation = generation
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
    generation.end()
    tasks.forEach { $0.cancel() }
    tasks = []
    running.values.forEach { $0.cancel() }
  }

  func fetch(_ key: String) async throws -> URL {
    do {
      return try await fetching(key)
    } catch is CancellationError where generation.isOver {
      throw FileFetchFailure.notSyncing
    }
  }

  private func fetching(_ key: String) async throws -> URL {
    if let url = files.fileURL(for: key) { return url }
    if let skip = skipped[key] { throw skip.error }
    demand[key, default: 0] += 1
    defer { release(key) }
    if let task = running[key] { return try await generation.outcome(of: task) }
    try await admitted()
    let attachment: Attachment
    if let found = known[key] { attachment = found } else { attachment = try await record(of: key) }
    try await admitted()
    if let url = files.fileURL(for: key) { return url }
    return try await generation.outcome(of: running[key] ?? begin(attachment, automatic: false))
  }

  private func admitted() async throws {
    let due = coordinator.retryDue.stream()
    while true {
      guard !generation.isOver, await coordinator.canSync else { throw FileFetchFailure.notSyncing }
      if await coordinator.admits(.fileDownload(urgent: true)) { return }
      let next = Task { () throws -> Void in for await _ in due { break } }
      do {
        try await generation.outcome(of: next)
      } catch {
        next.cancel()
        _ = await next.result
        throw error
      }
    }
  }

  private func release(_ key: String) {
    let left = (demand[key] ?? 1) - 1
    demand[key] = left > 0 ? left : nil
    if left <= 0, !automatic.contains(key) { running[key]?.cancel() }
  }

  private func record(of key: String) async throws -> Attachment {
    let answer = Promise<Attachment>()
    waiters.append((key, answer))
    defer { waiters.removeAll { $0.answer === answer } }
    return try await generation.value(of: answer)
  }

  private func seen(_ rows: [Attachment]) async {
    known = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    skipped = skipped.filter { known[$0.key] == $0.value.attachment }
    for waiter in waiters {
      if let attachment = known[waiter.key] { waiter.answer.resolve(.success(attachment)) }
    }
    await scan()
  }

  private func scan() async {
    guard !generation.isOver, automatic.count < Self.parallel, await coordinator.canSync, await coordinator.admits(.fileDownload(urgent: false)) else { return }
    for (key, attachment) in known where automatic.count < Self.parallel {
      guard running[key] == nil, skipped[key] == nil, Self.wanted(attachment), files.fileURL(for: key) == nil else { continue }
      begin(attachment, automatic: true)
    }
  }

  private static func wanted(_ attachment: Attachment) -> Bool {
    #if os(macOS)
    true
    #else
    attachment.byteCount <= phoneAutoLimit && !NetworkReturns.isMetered
    #endif
  }

  @discardableResult
  private func begin(_ attachment: Attachment, automatic isAutomatic: Bool) -> Task<URL, any Error> {
    let key = attachment.key
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
      guard let record else { throw skip(attachment, key, CKError(.unknownItem)) }
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
      throw CancellationError()
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
