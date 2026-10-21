import CryptoKit
import CueText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片文件：按内容哈希（SHA-256 十六进制）存放在库文件旁的 `Attachments/`，文件名就是哈希。是附件目录的唯一入口。
///
/// 读写都不经过 `CueStore` actor，编辑器可在主线程同步调用。附件记录（同步用）不在这里写：
/// 引用图片的写入（卡片正文、投送请求、发送记录、对话里你的消息）在同一事务里为本机已有文件的哈希登记，
/// 所以没被引用的图片不上传，被引用的本机图片一定有记录。
public struct AttachmentFiles: Sendable {
  let directory: URL
  /// 这个库的缓存目录（`LibraryLocation.caches`）：按文件名放的那份在这里，界面的缩略图与快照也放这里。
  public let caches: URL
  private static let chunkSize = 1 << 20

  /// 存入图片数据，返回内容哈希（写进正文的 `cuepad://img/<哈希>`）。同哈希文件已在则不重写、不再解析；不是图片抛 `notAnImage`。
  public func store(_ data: Data) throws -> String {
    let hash = SHA256.hash(data: data).hex
    let url = directory.appending(path: hash)
    guard !FileManager.default.fileExists(atPath: url.path) else { return hash }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), Self.isImage(source) else {
      throw CueStoreError.notAnImage
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    return hash
  }

  /// 存入图片文件（拖入、分享）：边读边算哈希再拷贝，整张图不进内存。
  public func store(fileAt source: URL) throws -> String {
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), Self.isImage(image) else {
      throw CueStoreError.notAnImage
    }
    let hash = try Self.hash(of: source)
    try place(source, as: hash)
    return hash
  }

  /// 存入任意文件（预览用）：边读边算哈希再拷贝，同哈希已在则不重写。不检查内容是不是图片。
  func storeFile(at source: URL) throws -> String {
    let hash = try Self.hash(of: source)
    try place(source, as: hash)
    return hash
  }

  /// 原图文件位置；格式不合法或文件不存在（例如尚未从 iCloud 下载）返回 nil。
  public func fileURL(for hash: String) -> URL? {
    guard Self.isValid(hash) else { return nil }
    let url = directory.appending(path: hash)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// 按文件名放的一份（缓存目录里，同卷克隆不占额外空间，系统可随时清理）：附件目录里的文件以哈希为名、没有扩展名，
  /// 系统的快速查看、"存到文件"与 Agent 的读文件工具都按扩展名认类型。文件不在本机返回 nil。
  public func named(_ hash: String, as name: String) -> URL? {
    guard let original = fileURL(for: hash) else { return nil }
    let directory = caches.appending(path: "CuePadPreviews", directoryHint: .isDirectory).appending(path: hash, directoryHint: .isDirectory)
    // 文件名来自同步的记录：不能带路径
    let target = directory.appending(path: name.replacing("/", with: "_").replacing("..", with: "_"))
    guard !FileManager.default.fileExists(atPath: target.path) else { return target }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: original, to: target)
      return target
    } catch {
      return nil
    }
  }

  /// 原图字节。哈希格式不合法或文件不存在都是 notFound（不会越出附件目录）。
  public func original(hash: String) throws -> Data {
    guard let url = fileURL(for: hash), let data = try? Data(contentsOf: url) else { throw CueStoreError.notFound }
    return data
  }

  /// 同步下载的附件文件：内容哈希必须与声明一致，才按哈希放进附件目录；已有同哈希文件则不重写。
  /// 记录本身坏了抛 `invalidAttachmentHash`、`attachmentHashMismatch`；其余（读下载的文件、建目录、拷贝、改名）是本机的失败，原样抛出。
  package func adopt(fileAt source: URL, hash: String) throws {
    guard Self.isValid(hash) else { throw CueStoreError.invalidAttachmentHash }
    guard try Self.hash(of: source) == hash else { throw CueStoreError.attachmentHashMismatch }
    try place(source, as: hash)
  }

  /// 删除文件；文件本来就不存在不算失败。
  func remove(hash: String) throws {
    let url = directory.appending(path: hash)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }

  /// 清空附件目录（账号切换后丢弃本机数据时用）。
  package func removeAll() throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }

  /// 登记附件记录所需的元数据；文件不在本机返回 nil。不是图片的文件（预览）格式是 "bin"。
  func metadata(hash: String) -> (byteCount: Int, format: String)? {
    guard let url = fileURL(for: hash), let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return (size, "bin") }
    return (size, UTType(type as String)?.preferredFilenameExtension ?? "bin")
  }

  /// 先拷到目录内的临时名再改名：别的进程或线程永远看不到写了一半的文件。
  private func place(_ source: URL, as hash: String) throws {
    let url = directory.appending(path: hash)
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let partial = directory.appending(path: ".\(hash).\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: partial)
    do {
      try FileManager.default.moveItem(at: partial, to: url)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      guard FileManager.default.fileExists(atPath: url.path) else { throw error }  // 同时存入同一张图：已有即可
    }
  }

  private static func hash(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().hex
  }

  private static func isImage(_ source: CGImageSource) -> Bool {
    CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
  }

  private static func isValid(_ hash: String) -> Bool {
    hash.utf8.count == 64 && hash.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
  }
}

extension CueStore {
  /// 为正文里引用、本机已有文件、还没有记录的图片登记附件记录。必须在写事务内调用。
  func registerImages(in text: String) throws {
    for hash in Set(CueFormat.imageHashes(in: text)) { try registerAttachment(hash: hash) }
  }

  /// 这张图片有没有附件记录。记录在文件到本机之后才有（本机登记，或同步来的文件落盘后）：界面据此等远端的图片到达，订阅它就会在到达时醒来。
  public func hasAttachment(_ hash: String) throws -> Bool {
    try db.first("SELECT 1 FROM attachments WHERE hash = ?", [hash], { _ in true }) != nil
  }

  /// 本机已有这个文件、还没有记录时登记附件记录（同步载体）。必须在写事务内调用。
  func registerAttachment(hash: String) throws {
    guard try !hasAttachment(hash), let metadata = files.metadata(hash: hash) else { return }
    let now = Date.stamp
    try insert(
      Attachment(id: UUID(), hash: hash, byteCount: metadata.byteCount, format: metadata.format, createdAt: now, modifiedAt: now))
  }
}

/// 图片附件元数据；文件按内容哈希存在磁盘，缩略图是派生缓存不入库。
public struct Attachment: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var hash: String
  public var byteCount: Int
  public var format: String
  public var createdAt: Date
  public var modifiedAt: Date
}

extension Attachment: Record {
  static let table = Table.attachments
  static let columns = ["id", "hash", "byteCount", "format", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, hash, byteCount, format, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(id: row.uuid(0), hash: row.text(1), byteCount: Int(row.int(2)), format: row.text(3), createdAt: row.date(4), modifiedAt: row.date(5))
  }
}
