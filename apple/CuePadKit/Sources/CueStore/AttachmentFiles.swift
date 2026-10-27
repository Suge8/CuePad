import CryptoKit
import CueText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 附件文件（图片与任意文件）的唯一入口：按键（`AttachmentKey`）存取，本机只有一份，在库的缓存目录 `CuePadAttachments/<键>`；
/// 快速查看、交给 Agent 与 Cue 的都是这条路径。iCloud 是事实源，缓存可被系统清掉，要用时再从 iCloud 取（`CueSync`）。
/// 例外只有一条：服务器收下附件记录之前，库旁 `Attachments/<键>` 留一个硬链接保底（同一份数据，不多占空间；没登录 iCloud 就一直留着），
/// 收下后删（`uploaded`）；缓存那份被清掉而保底还在，由保底补回。
///
/// 读写都不经过 `CueStore` actor，编辑器可在主线程同步调用。附件记录（同步用）不在这里写：
/// 引用附件的写入（卡片正文、投送请求、发送记录、对话里的消息、预览）在同一事务里为本机已有文件的键登记，
/// 所以没被引用的文件不上传，被引用的本机文件一定有记录。
public struct AttachmentFiles: Sendable {
  /// 保底的硬链接所在（库旁的 `Attachments/`）
  let backups: URL
  /// 本机那份所在（缓存目录的 `CuePadAttachments/`；Mac 上没有沙盒，缓存目录是各家共用的 `~/Library/Caches`，所以带前缀）。
  /// 交给 Agent 的路径都在这里面：托管的 Claude Code 起进程时加进可读目录、OpenCode 的服务放行它。
  public let directory: URL
  /// 这个库的缓存目录（`LibraryLocation.caches`）：附件、界面的缩略图与快照都放这里。
  public let caches: URL
  /// 单个文件上限：经 iCloud 同步，手机上也要取得下来。
  public static let maxBytes = 500_000_000
  private static let chunkSize = 1 << 20

  init(library: URL, caches: URL) {
    backups = library.appending(path: "Attachments", directoryHint: .isDirectory)
    directory = caches.appending(path: "CuePadAttachments", directoryHint: .isDirectory)
    self.caches = caches
  }

  /// 存入数据（粘贴的图片等），返回键：扩展名按 ImageIO 认出的类型，认不出没有扩展名。超过 `maxBytes` 抛 `fileTooLarge`。
  public func store(_ data: Data) throws -> String {
    guard data.count <= Self.maxBytes else { throw CueStoreError.fileTooLarge(limit: Self.maxBytes) }
    let key = AttachmentKey.make(hash: SHA256.hash(data: data).hex, format: Self.imageFormat(CGImageSourceCreateWithData(data as CFData, nil)))
    try place(key) { try data.write(to: $0) }
    return key
  }

  /// 存入文件（拖入、分享、Agent 发来的），返回键：边读边算哈希再拷贝，整个文件不进内存。扩展名取文件名的，
  /// 文件名没有扩展名时按 ImageIO 认出的类型。超过 `maxBytes` 抛 `fileTooLarge`。
  public func store(fileAt source: URL) throws -> String {
    let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
    guard size <= Self.maxBytes else { throw CueStoreError.fileTooLarge(limit: Self.maxBytes) }
    let hash = try Self.hash(of: source)
    var format = AttachmentKey.format(ofName: source.lastPathComponent)
    if format.isEmpty { format = Self.imageFormat(CGImageSourceCreateWithURL(source as CFURL, nil)) }
    let key = AttachmentKey.make(hash: hash, format: format)
    try place(key) { try FileManager.default.copyItem(at: source, to: $0) }
    return key
  }

  /// 本机那份的位置；键不合法或本机没有（还没从 iCloud 取来、缓存被清掉）为 nil。缓存被清掉而保底还在时先由保底补回。
  public func fileURL(for key: String) -> URL? {
    guard AttachmentKey.isValid(key) else { return nil }
    let url = directory.appending(path: key)
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let backup = backups.appending(path: key)
    guard FileManager.default.fileExists(atPath: backup.path) else { return nil }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.linkItem(at: backup, to: url)
      return url
    } catch {
      return FileManager.default.fileExists(atPath: url.path) ? url : nil  // 同时补回：已有即可
    }
  }

  /// 同步下载的附件文件：内容哈希必须与键一致，才放进本机；已有同键文件则不重写。
  /// 记录本身坏了抛 `invalidAttachmentHash`、`attachmentHashMismatch`；其余（读下载的文件、建目录、拷贝、改名）是本机的失败，原样抛出。
  package func adopt(fileAt source: URL, key: String) throws {
    guard let hash = AttachmentKey.parts(key)?.hash else { throw CueStoreError.invalidAttachmentHash }
    guard try Self.hash(of: source) == hash else { throw CueStoreError.attachmentHashMismatch }
    try place(key, backup: false) { try FileManager.default.copyItem(at: source, to: $0) }
  }

  /// 服务器收下了这个附件记录：删保底。本来就没有不算失败。
  package func uploaded(_ key: String) throws {
    try Self.removeIfPresent(backups.appending(path: key))
  }

  /// 删除本机那份与保底；本来就不存在不算失败。
  package func remove(_ key: String) throws {
    try Self.removeIfPresent(directory.appending(path: key))
    try Self.removeIfPresent(backups.appending(path: key))
  }

  /// 清空本机的附件与保底（账号切换后丢弃本机数据时用）。
  package func removeAll() throws {
    try Self.removeIfPresent(directory)
    try Self.removeIfPresent(backups)
  }

  /// 登记附件记录所需的元数据（`format` 就是键的扩展名）；文件不在本机返回 nil。
  func metadata(_ key: String) -> (hash: String, byteCount: Int, format: String)? {
    guard let parts = AttachmentKey.parts(key), let url = fileURL(for: key),
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    else { return nil }
    return (parts.hash, size, parts.format)
  }

  /// 先写到目录内的临时名再改名：别的进程或线程永远看不到写了一半的文件。新放进来的、要上传的（不是从 iCloud 取来的）先留好保底再改名，
  /// 所以留不下保底就什么都没存。
  private func place(_ key: String, backup: Bool = true, write: (URL) throws -> Void) throws {
    let url = directory.appending(path: key)
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let partial = directory.appending(path: ".\(key).\(UUID().uuidString)")
    try write(partial)
    do {
      if backup { try link(partial, to: backups.appending(path: key)) }
      try FileManager.default.moveItem(at: partial, to: url)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      guard FileManager.default.fileExists(atPath: url.path) else { throw error }  // 同时存入同一份：已有即可
    }
  }

  func link(_ file: URL, to backup: URL) throws {
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    do { try FileManager.default.linkItem(at: file, to: backup) } catch let error as CocoaError where error.code == .fileWriteFileExists {}
  }

  private static func removeIfPresent(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }

  /// ImageIO 认出的图片类型的扩展名；不是图片为空。
  static func imageFormat(_ source: CGImageSource?) -> String {
    guard let source, CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) else { return "" }
    return UTType(type as String)?.preferredFilenameExtension ?? ""
  }

  private static func hash(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().hex
  }
}

extension CueStore {
  /// 为正文里引用、本机已有文件、还没有记录的附件登记附件记录。必须在写事务内调用。
  func registerAttachments(in text: String) throws {
    for key in Set(CueFormat.attachmentKeys(in: text)) { try registerAttachment(key) }
  }

  /// 这个键有没有附件记录。记录随别的记录一起先到，文件另走一路后到：有记录不等于文件在本机（`AttachmentFiles.fileURL`）。
  public func hasAttachment(_ key: String) throws -> Bool {
    guard let parts = AttachmentKey.parts(key) else { return false }
    return try db.first("SELECT 1 FROM attachments WHERE hash = ? AND format = ?", [parts.hash, parts.format], { _ in true }) != nil
  }

  /// 本机已有这个文件、还没有记录时登记附件记录（同步载体）。必须在写事务内调用。
  /// 记录已有、服务器也收下过的（同一份内容再存了一次）：存入时新留的保底用不着，删掉。
  func registerAttachment(_ key: String) throws {
    guard try !hasAttachment(key) else {
      if try isUploaded(key) { try files.uploaded(key) }
      return
    }
    guard let metadata = files.metadata(key) else { return }
    let now = Date.stamp
    try insert(
      Attachment(id: UUID(), hash: metadata.hash, byteCount: metadata.byteCount, format: metadata.format, createdAt: now, modifiedAt: now))
  }
}

extension CueStore {
  /// 这个键的附件记录服务器收下过（有一版推送成功）。
  func isUploaded(_ key: String) throws -> Bool {
    guard let parts = AttachmentKey.parts(key) else { return false }
    return try db.first(
      """
      SELECT 1 FROM attachments a JOIN syncRecords s ON s.recordName = a.id
      WHERE a.hash = ? AND a.format = ? AND s.pushedModifiedAt IS NOT NULL
      """, [parts.hash, parts.format]) { _ in true } != nil
  }
}

/// 附件记录（同步表 `attachments`）：键 = `hash` + `format`（`AttachmentKey`），文件经它的资产字段同步；缩略图是派生缓存不入库。
public struct Attachment: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var hash: String
  public var byteCount: Int
  /// 键的扩展名，没有为空
  public var format: String
  public var createdAt: Date
  public var modifiedAt: Date

  public var key: String { AttachmentKey.make(hash: hash, format: format) }
}

extension Attachment: Record {
  static let table = Table.attachments
  static let columns = ["id", "hash", "byteCount", "format", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, hash, byteCount, format, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(id: row.uuid(0), hash: row.text(1), byteCount: Int(row.int(2)), format: row.text(3), createdAt: row.date(4), modifiedAt: row.date(5))
  }
}
