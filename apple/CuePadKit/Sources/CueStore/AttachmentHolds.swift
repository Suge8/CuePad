import CueText
import Foundation
import Synchronization

final class AttachmentRun: Sendable {
  let holds: URL
  let id = UUID().uuidString
  private let lockState = Mutex<Lock>(.notTaken)

  private enum Lock {
    case notTaken
    case made(Int32?)
    case released
  }

  /// iOS 上进程随时会被挂起，挂起时还锁着 App Group 容器里的文件，系统就以 0xdead10cc 结束它（TN2408：flock 与 DELETE 模式的 SQLite 一样，
  /// 挂起即杀；WAL 模式只在挂着写事务时杀）。那里写库的只有 App 一个进程（分享扩展经 `CaptureQueue` 交给 App，小组件只读快照），
  /// 清理只在 App 启动时跑，那时上一个 App 进程已经结束：别的运行都已结束，不必靠锁分辨，所以 iOS 上建目录、清理都不碰 flock，挂起落在哪一步都没有锁。
  /// 否决了只缩短持锁（建好目录就放、清理时拿着锁删）：挂起正好落在那一下照样被杀；也否决了进后台放锁、回前台再拿：
  /// 后台推送、后台刷新也会存入附件（取文件、收分享），每条进后台的路都要配一次放锁，漏一条就又被杀。
  #if os(iOS)
  private static let locks = false
  #else
  private static let locks = true
  #endif

  init(holds: URL) { self.holds = holds }

  var location: URL { holds.appending(path: id, directoryHint: .isDirectory) }

  /// 建好并返回这次运行的持有目录。先拿锁再建目录：看得到目录时锁一定拿着（iOS 上没有锁，`locks`）；崩在两步之间只留一个锁文件，清理照样收。
  /// 锁的描述符不传给子进程：比 App 活得久的 Agent 进程不能替它占着锁。
  func folder() throws -> URL {
    try lockState.withLock { state in
      switch state {
      case .made: return
      case .released: preconditionFailure("运行已结束，不能再存入")
      case .notTaken: break
      }
      try FileManager.default.createDirectory(at: holds, withIntermediateDirectories: true)
      let opened = Self.locks ? try Self.takeLock(Self.lock(id, in: holds)) : nil
      do { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) } catch {
        if let opened { close(opened) }
        throw error
      }
      state = .made(opened)
    }
    return location
  }

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

  static func ids(in holds: URL) -> Set<String> {
    Set(AttachmentFiles.names(in: holds).map { $0.hasSuffix(".lock") ? String($0.dropLast(5)) : $0 })
  }

  static func removeIfEnded(_ id: String, in holds: URL) throws {
    let lock = lock(id, in: holds)
    var opened: Int32?
    if locks {
      opened = open(lock.path, O_RDWR | O_CLOEXEC)
      guard let opened, opened >= 0 else { return }
    }
    defer { if let opened { close(opened) } }
    if let opened { guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { return } }
    try AttachmentFiles.removeIfPresent(holds.appending(path: id, directoryHint: .isDirectory))
    try AttachmentFiles.removeIfPresent(lock)
  }

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
  package func endRun() { run.end() }

  func hold(_ file: URL, as key: String) throws {
    try link(file, to: run.folder().appending(path: key))
  }

  func restoredFromAnyRun(_ key: String) -> URL? {
    restored(key, from: [backups] + AttachmentRun.folders(in: run.holds))
  }

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
