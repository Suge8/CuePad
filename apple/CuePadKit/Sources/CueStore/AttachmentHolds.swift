import CueText
import Foundation
import Synchronization

/// 一次运行的持有：打开着的库（一个进程一份）在 `Attachments/holds/<运行>/` 里为这次存入过的每个键留一个硬链接，
/// 对 `<运行>.lock` 的 flock 拿到进程结束，崩溃时由内核放掉。第一次存入时才建，只读的进程不留目录。
/// 存入先留好持有才返回键（`AttachmentFiles.place`）；回收（本机永久删除、远端删除、启动清理）只删缓存与保底，活着的运行的持有谁也不删，
/// 所以已存好、还没提交引用的写者在提交时照样从持有补回、登记；提交回滚了，持有还在，可以重试。
/// 结束了的运行只由 App 的启动清理删（`CueStore.removeStrayFiles`）：草稿只在 App 的设置里、库里看不到，先把它们引用的键挪进这次运行。
/// 代价：这次运行存过、又被永久删除的附件，要等进程结束后的下一次启动清理才释放磁盘，上限是这次运行存过又删掉的附件总量；
/// 命令行这类不跑启动清理的进程留下的，等 App 下次启动。
final class AttachmentRun: Sendable {
  /// 各运行的持有目录与锁文件所在
  let holds: URL
  let id = UUID().uuidString
  private let descriptor = Mutex<Int32?>(nil)

  init(holds: URL) { self.holds = holds }

  /// 这次运行的持有目录。先拿锁再建目录：清理只认目录，看得到目录时锁一定已经拿着。
  /// 锁的描述符不传给子进程：比 App 活得久的 Agent 进程不能替它占着锁。
  func folder() throws -> URL {
    let folder = holds.appending(path: id, directoryHint: .isDirectory)
    try descriptor.withLock { held in
      guard held == nil else { return }
      try FileManager.default.createDirectory(at: holds, withIntermediateDirectories: true)
      let opened = open(Self.lock(id, in: holds).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
      guard opened >= 0 else { throw Self.posixError() }
      do {
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { throw Self.posixError() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      } catch {
        close(opened)
        throw error
      }
      held = opened
    }
    return folder
  }

  deinit { descriptor.withLock { if let held = $0 { close(held) } } }

  /// 各运行（活着的与结束了还没清的）的持有目录。
  static func folders(in holds: URL) -> [URL] {
    AttachmentFiles.names(in: holds).filter { !$0.hasSuffix(".lock") }.map { holds.appending(path: $0, directoryHint: .isDirectory) }
  }

  /// 这个运行已经结束（锁拿得到）就拿着锁删掉它的持有目录与锁文件。还活着的、锁文件不在的（锁先于目录建、后于目录删）不碰。
  static func removeIfEnded(_ folder: URL) throws {
    let lock = lock(folder.lastPathComponent, in: folder.deletingLastPathComponent())
    let opened = open(lock.path, O_RDWR | O_CLOEXEC)
    guard opened >= 0 else { return }
    defer { close(opened) }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { return }
    try FileManager.default.removeItem(at: folder)
    try FileManager.default.removeItem(at: lock)
  }

  private static func lock(_ id: String, in holds: URL) -> URL { holds.appending(path: "\(id).lock") }

  private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

extension AttachmentFiles {
  /// 在这次运行里持有 `file`（`key` 的那一份）。
  func hold(_ file: URL, as key: String) throws {
    try link(file, to: run.folder().appending(path: key))
  }

  /// 缓存之外留着这个键的那几份：保底，或哪个运行的持有。结束了还没清的运行也算：按键存的内容都是同一份。
  func keptCopies(of key: String) -> some Sequence<URL> {
    ([backups] + AttachmentRun.folders(in: run.holds)).lazy.map { $0.appending(path: key) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// 启动清理的头一步：`drafted` 里本机有的键挪进这次运行，再删结束了的运行留下的持有。
  func endFinishedRuns(keeping drafted: Set<String>) throws {
    for key in drafted { if let file = fileURL(for: key) { try hold(file, as: key) } }
    for folder in AttachmentRun.folders(in: run.holds) where folder.lastPathComponent != run.id { try AttachmentRun.removeIfEnded(folder) }
  }

  /// 缓存与保底里没有哪个运行持有的键：启动清理的候选。
  func unheldKeys() -> Set<String> {
    let held = Set(AttachmentRun.folders(in: run.holds).flatMap(Self.names(in:)))
    return Set([directory, backups].flatMap(Self.names(in:)).filter(AttachmentKey.isValid)).subtracting(held)
  }

  static func names(in folder: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
}
