import CueText
import Foundation
import Synchronization

/// 一次运行的持有：打开着的库（一个进程一份）在 `Attachments/holds/<运行>/` 里为这次存入过的每个键留一个硬链接，
/// 对 `<运行>.lock` 的 flock 拿到进程结束，崩溃时由内核放掉（iOS 上不留着，见 `keepsLock`）。第一次存入时才建，只读的进程不留目录。
/// 存入先留好持有才返回键（`AttachmentFiles.place`）；回收（本机永久删除、远端删除、启动清理、账号切换清空）只删缓存与保底，活着的运行的持有谁也不删，
/// 所以已存好、还没提交引用的写者在提交时照样从自己的持有补回、登记；提交回滚了，持有还在，可以重试。
/// 只有存入它的运行从自己的持有补回（`AttachmentFiles.fileURL`）：别的进程不会去引用它没存过的键，查找也不随运行数变慢。
/// 结束了的运行只由 App 的启动清理删（`CueStore.removeStrayFiles`）：草稿只在 App 的设置里、库里看不到，先把它们引用的键从各运行挪进这次运行。
/// 代价：这次运行存过、又被永久删除或随账号清空的附件，要等进程结束后的下一次启动清理才释放磁盘，上限是这次运行存过又删掉的附件总量；
/// 命令行这类不跑启动清理的进程留下的，等 App 下次启动。
final class AttachmentRun: Sendable {
  let holds: URL
  let id = UUID().uuidString
  private let lockState = Mutex<Lock>(.notTaken)

  private enum Lock {
    case notTaken
    /// 目录已建；锁的描述符，不留着锁时为 nil。
    case made(Int32?)
    case released
  }

  /// iOS 上进程随时会被挂起，挂起时还锁着 App Group 容器里的文件，系统就以 0xdead10cc 结束它（TN2408：flock 与 DELETE 模式的 SQLite 一样，
  /// 挂起即杀；WAL 模式只在挂着写事务时杀）。那里写库的只有 App 一个进程（分享扩展经 `CaptureQueue` 交给 App，小组件只读快照），
  /// 清理只在 App 启动时跑，那时上一个 App 进程已经结束：别的运行都已结束，不必靠锁分辨，建好目录就放锁。锁文件照建，清理按它认运行。
  /// 否决了进后台放锁、回前台再拿：后台推送、后台刷新也会存入附件（取文件、收分享），每条进后台的路都要配一次放锁，漏一条就又被杀。
  #if os(iOS)
  private static let keepsLock = false
  #else
  private static let keepsLock = true
  #endif

  init(holds: URL) { self.holds = holds }

  var location: URL { holds.appending(path: id, directoryHint: .isDirectory) }

  /// 建好并返回这次运行的持有目录。先拿锁再建目录：看得到目录时锁一定拿着（iOS 上只拿到建好目录，`keepsLock`）；崩在两步之间只留一个锁文件，清理照样收。
  /// 锁的描述符不传给子进程：比 App 活得久的 Agent 进程不能替它占着锁。
  func folder() throws -> URL {
    try lockState.withLock { state in
      switch state {
      case .made: return
      case .released: preconditionFailure("运行已结束，不能再存入")
      case .notTaken: break
      }
      try FileManager.default.createDirectory(at: holds, withIntermediateDirectories: true)
      let opened = try Self.takeLock(Self.lock(id, in: holds))
      do { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) } catch {
        close(opened)
        throw error
      }
      if Self.keepsLock {
        state = .made(opened)
      } else {
        close(opened)
        state = .made(nil)
      }
    }
    return location
  }

  /// 当场放掉锁，这次运行从此算结束：别的运行的启动清理可以收走它的持有。之后不能再存入。
  /// 进程退出时内核放锁、释放时 deinit 放锁都不必调它；释放的时刻不由调用方定（跨进程通知的处理还握着 `CueStore`，实测晚十几到几十毫秒），
  /// 要在同一进程里紧接着认定它结束的（测试里模拟结束了的进程）用这个。
  func end() {
    lockState.withLock { state in
      if case .made(let opened?) = state { close(opened) }
      state = .released
    }
  }

  deinit { end() }

  static func folders(in holds: URL) -> [URL] {
    AttachmentFiles.names(in: holds).filter { !$0.hasSuffix(".lock") }.map { holds.appending(path: $0, directoryHint: .isDirectory) }
  }

  /// 有目录的，和只剩锁文件的（崩在建锁与建目录之间、删目录与删锁之间）。
  static func ids(in holds: URL) -> Set<String> {
    Set(AttachmentFiles.names(in: holds).map { $0.hasSuffix(".lock") ? String($0.dropLast(5)) : $0 })
  }

  static func removeIfEnded(_ id: String, in holds: URL) throws {
    let lock = lock(id, in: holds)
    let opened = open(lock.path, O_RDWR | O_CLOEXEC)
    guard opened >= 0 else { return }
    defer { close(opened) }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { return }
    try AttachmentFiles.removeIfPresent(holds.appending(path: id, directoryHint: .isDirectory))
    try AttachmentFiles.removeIfPresent(lock)
  }

  /// 打开并锁上锁文件。清理拿着锁删只剩锁文件的运行，可能正好删在这里打开之后、锁上之前：锁上的已不是那个路径上的文件就重来。
  private static func takeLock(_ lock: URL) throws -> Int32 {
    while true {
      let opened = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
      guard opened >= 0 else { throw posixError() }
      guard flock(opened, LOCK_EX) == 0 else {
        let error = posixError()
        close(opened)
        throw error
      }
      var locked = stat(), named = stat()
      if fstat(opened, &locked) == 0, stat(lock.path, &named) == 0, locked.st_dev == named.st_dev, locked.st_ino == named.st_ino { return opened }
      close(opened)
    }
  }

  private static func lock(_ id: String, in holds: URL) -> URL { holds.appending(path: "\(id).lock") }

  private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

extension AttachmentFiles {
  /// 当场结束这次运行（`AttachmentRun.end`）：同一进程里模拟“存过这些文件的进程已经退出”。
  package func endRun() { run.end() }

  func hold(_ file: URL, as key: String) throws {
    try link(file, to: run.folder().appending(path: key))
  }

  /// 缓存里那份；不在就从保底或任一运行（结束了还没清的也算，按键存的内容都是同一份）的持有链回。只在存入与启动清理用：要列出所有运行目录。
  func restoredFromAnyRun(_ key: String) -> URL? {
    restored(key, from: [backups] + AttachmentRun.folders(in: run.holds))
  }

  /// 删不掉的运行（权限、文件被锁）不挡别的，连同错误交回；草稿的键挪不进来就整个停下：不然它唯一的那份会随结束的运行删掉。
  func endFinishedRuns(keeping drafted: Set<String>) throws -> [(run: String, error: any Error)] {
    for key in drafted { if let file = restoredFromAnyRun(key) { try hold(file, as: key) } }
    var failures: [(run: String, error: any Error)] = []
    for id in AttachmentRun.ids(in: run.holds).sorted() where id != run.id {
      do { try AttachmentRun.removeIfEnded(id, in: run.holds) } catch { failures.append((id, error)) }
    }
    return failures
  }

  func heldKeys() -> Set<String> {
    Set(AttachmentRun.folders(in: run.holds).flatMap(Self.names(in:)).filter(AttachmentKey.isValid))
  }

  func unheldKeys() -> Set<String> {
    Set([directory, backups].flatMap(Self.names(in:)).filter(AttachmentKey.isValid)).subtracting(heldKeys())
  }

  static func names(in folder: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
}
