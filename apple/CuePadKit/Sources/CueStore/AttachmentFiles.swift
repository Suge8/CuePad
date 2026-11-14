import CryptoKit
import CueText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 本机只有一份数据，在库的缓存目录 `CuePadAttachments/<键>`；iCloud 是事实源，缓存可被系统清掉，要用时再从 iCloud 取（`CueSync`）。
/// 丢了就找不回的时候，库旁另留一个硬链接（同一份数据，不多占空间），缓存那份被清掉、被回收删掉时由它补回：持有 `Attachments/holds/<运行>/<键>`（存入的进程还在、引用可能还没提交，`AttachmentRun`）与保底 `Attachments/<键>`（引用提交、登记了附件记录之后，到服务器收下为止；没登录 iCloud 就一直留着）。
/// 读写都不经过 `CueStore` actor，编辑器可在主线程同步调用。附件记录不在这里写：引用附件的写入在同一事务里为本机已有文件的键登记，所以没被引用的文件不上传，被引用的本机文件一定有记录。
public struct AttachmentFiles: Sendable {
  let backups: URL
  /// Mac 上没有沙盒，缓存目录是各家共用的 `~/Library/Caches`，所以带前缀。交给 Agent 的路径都在这里面：托管的 Claude Code 起进程时加进可读目录、OpenCode 的服务放行它。
  public let directory: URL
  public let caches: URL
  /// 单个文件上限：经 iCloud 同步，手机上也要取得下来。
  public static let maxBytes = 500_000_000
  private static let chunkSize = 1 << 20

  let run: AttachmentRun

  init(library: URL, caches: URL) {
    backups = library.appending(path: "Attachments", directoryHint: .isDirectory)
    directory = caches.appending(path: "CuePadAttachments", directoryHint: .isDirectory)
    self.caches = caches
    run = AttachmentRun(holds: backups.appending(path: "holds", directoryHint: .isDirectory))
  }

  /// 扩展名按 ImageIO 认出的类型，认不出没有扩展名。超过 `maxBytes` 抛 `fileTooLarge`。
  public func store(_ data: Data) throws -> String {
    guard data.count <= Self.maxBytes else { throw CueStoreError.fileTooLarge(limit: Self.maxBytes) }
    let key = AttachmentKey.make(hash: SHA256.hash(data: data).hex, format: Self.imageFormat(CGImageSourceCreateWithData(data as CFData, nil)))
    try place(key) { try data.write(to: $0) }
    return key
  }

  /// 边读边算哈希再拷贝，整个文件不进内存。扩展名取文件名的，没有时按 ImageIO 认出的类型。超过 `maxBytes` 抛 `fileTooLarge`。
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

  /// 键不合法或本机没有为 nil。缓存里没有而保底或这次运行的持有还在时先补回：界面在主线程按它画图，查找只看这两处，不随运行目录的多少变慢。
  public func fileURL(for key: String) -> URL? {
    guard AttachmentKey.isValid(key) else { return nil }
    return restored(key, from: [backups, run.location])
  }

  /// 内容哈希必须与键一致才放进本机。记录本身坏了抛 `invalidAttachmentHash`、`attachmentHashMismatch`；其余是本机的失败，原样抛出。
  package func adopt(fileAt source: URL, key: String) throws {
    guard let hash = AttachmentKey.parts(key)?.hash else { throw CueStoreError.invalidAttachmentHash }
    guard try Self.hash(of: source) == hash else { throw CueStoreError.attachmentHashMismatch }
    try place(key, held: false) { try FileManager.default.copyItem(at: source, to: $0) }
  }

  func uploaded(_ key: String) throws {
    try Self.removeIfPresent(backups.appending(path: key))
  }

  package func remove(_ key: String) throws {
    try Self.removeIfPresent(directory.appending(path: key))
    try Self.removeIfPresent(backups.appending(path: key))
  }

  /// 持有照 `AttachmentRun` 的规则不动：还活着的运行可能还要把存好的提交进新账号。别的运行的读不到，磁盘等它们结束后的启动清理释放。不是隐私边界。
  func removeAll() throws {
    try Self.removeIfPresent(directory)
    for name in Self.names(in: backups) where name != run.holds.lastPathComponent { try Self.removeIfPresent(backups.appending(path: name)) }
  }

  /// 文件不在本机返回 nil。回滚了只多一个没有记录的保底：持有它的运行结束后，启动清理收走。
  func keepUntilUploaded(_ key: String) throws -> (hash: String, byteCount: Int, format: String)? {
    guard let parts = AttachmentKey.parts(key), let url = fileURL(for: key) else { return nil }
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    try link(url, to: backups.appending(path: key))
    return (parts.hash, size, parts.format)
  }

  /// 先写到这次运行持有目录里的临时名再改名进缓存：别的进程或线程永远看不到写了一半的文件，崩在中间留下的随运行目录被启动清理收走。
  /// 存入的（不是从 iCloud 取来的）不论新写还是同一份已在，都先在这次运行里持有（`AttachmentRun`）才返回，持有不了就什么都没存；
  /// 已在的那份正好被回收删掉、链不上时，当新文件重写。
  private func place(_ key: String, held: Bool = true, write: (URL) throws -> Void) throws {
    let url = directory.appending(path: key)
    if let existing = restoredFromAnyRun(key) {
      guard held else { return }
      if (try? hold(existing, as: key)) != nil { return }
    }
    let partial = try run.folder().appending(path: ".\(key).\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: partial) }
    try write(partial)
    if held { try hold(partial, as: key) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do { try FileManager.default.moveItem(at: partial, to: url) } catch {
      guard FileManager.default.fileExists(atPath: url.path) else { throw error }  // 同时存入同一份：已有即可
    }
  }

  func restored(_ key: String, from sources: [URL]) -> URL? {
    let url = directory.appending(path: key)
    if FileManager.default.fileExists(atPath: url.path) { return url }
    for source in sources {
      let copy = source.appending(path: key)
      if FileManager.default.fileExists(atPath: copy.path), (try? link(copy, to: url)) != nil { return url }
    }
    return nil
  }

  func link(_ file: URL, to target: URL) throws {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try FileManager.default.linkItem(at: file, to: target) } catch let error as CocoaError where error.code == .fileWriteFileExists {}
  }

  static func removeIfPresent(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }

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

  /// 服务器收下了附件记录 `id`（CloudKit 的记录名）：它还是这个键现在的记录才删保底。上传途中它被永久删除、同一份内容又登记成新记录的，
  /// 新记录还没上传，保底留着。写事务里核对，与登记新记录（`registerAttachment` 留保底）不交错。
  package func attachmentUploaded(_ id: String) throws {
    try write {
      guard let id = UUID(uuidString: id), let attachment = try find(Attachment.self, id) else { return }
      try files.uploaded(attachment.key)
    }
  }

  /// 必须在写事务内调用。
  /// 记下是这台登记的（本机列 `registeredHere`）：启动清理只收这种，所以这台的引用都由自己那条撑着，不沿用别的设备登记的——
  /// 那台不再引用、清理收走它那条时，删除同步过来也不会让这里的引用没了记录。这台已登记过的（服务器收下过的同一份内容再存了一次也是）不再登记、不留保底。
  /// 代价：同一份内容每台引用过的各一条记录，各自经文件那一路上传一次（CloudKit 对同内容的资产去重，实测另一条只传约 0.1MB，见 `Schema.keyedAttachments`）；
  /// 结构 95 之前登记的不算这台的，升级后再引用时补登记一条。
  /// 文件不在本机时登记不了（记录要带文件），这条引用仍只靠别的设备那一条记录：那台不再引用这份内容并启动清理时，这台的卡片还没传过去，
  /// 这里的引用就没有文件了。本机离线、同步关着或在退避期间，这个窗口没有上限。这是两台设备离线时对同一份内容做了相反的编辑，有意接受。
  func registerAttachment(_ key: String) throws {
    guard let parts = AttachmentKey.parts(key),
      try db.first("SELECT 1 FROM attachments WHERE hash = ? AND format = ? AND registeredHere = 1", [parts.hash, parts.format], { _ in true }) == nil,
      let metadata = try files.keepUntilUploaded(key)
    else { return }
    let now = Date.stamp
    let attachment = Attachment(id: UUID(), hash: metadata.hash, byteCount: metadata.byteCount, format: metadata.format, createdAt: now, modifiedAt: now)
    try insert(attachment)
    try db.run("UPDATE attachments SET registeredHere = 1 WHERE id = ?", [attachment.id])
  }
}

public struct Attachment: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var hash: String
  public var byteCount: Int
  public var format: String
  public var createdAt: Date
  public var modifiedAt: Date

  public var key: String { AttachmentKey.make(hash: hash, format: format) }
}

extension Attachment: Record, SyncedColumns {
  static let table = Table.attachments
  static let fields: [Field] = [.plain("id"), .plain("hash"), .plain("byteCount"), .plain("format"), .plain("createdAt"), .plain("modifiedAt")]
  var bindings: [any SQLBindable] { [id, hash, byteCount, format, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(id: row.uuid(0), hash: row.text(1), byteCount: Int(row.int(2)), format: row.text(3), createdAt: row.date(4), modifiedAt: row.date(5))
  }
}
