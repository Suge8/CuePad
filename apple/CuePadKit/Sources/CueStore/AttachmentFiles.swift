import CryptoKit
import CueText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片文件：按内容哈希（SHA-256 十六进制）存放在库文件旁的 `Attachments/`，文件名就是哈希。是附件目录的唯一入口。
///
/// 读写都不经过 `CueStore` actor，编辑器可在主线程同步调用。附件记录（同步用）不在这里写：
/// 引用图片的写入（卡片正文、投送请求、发送记录）在同一事务里为本机已有文件的哈希登记，
/// 所以没被引用的图片不上传，被引用的本机图片一定有记录。
public struct AttachmentFiles: Sendable {
  let directory: URL
  private static let chunkSize = 1 << 20

  /// 存入图片数据，返回内容哈希（写进正文的 `cuepad://img/<哈希>`）。不是图片抛 `notAnImage`；同哈希文件已在则不重写。
  public func store(_ data: Data) throws -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), Self.isImage(source) else {
      throw CueStoreError.notAnImage
    }
    let hash = Self.hex(SHA256.hash(data: data))
    let url = directory.appending(path: hash)
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    }
    return hash
  }

  /// 存入图片文件（拖入、分享）：分块计算哈希后拷贝，整张图不进内存。
  public func store(fileAt source: URL) throws -> String {
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), Self.isImage(image) else {
      throw CueStoreError.notAnImage
    }
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

  /// 原图字节。哈希格式不合法或文件不存在都是 notFound（不会越出附件目录）。
  public func original(hash: String) throws -> Data {
    guard let url = fileURL(for: hash), let data = try? Data(contentsOf: url) else { throw CueStoreError.notFound }
    return data
  }

  /// 同步下载的附件文件：内容哈希必须与声明一致，才按哈希放进附件目录；已有同哈希文件则不重写。
  package func adopt(fileAt source: URL, hash: String) throws {
    guard Self.isValid(hash) else { throw CueStoreError.notFound }
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

  /// 登记附件记录所需的元数据；文件不在本机返回 nil。
  func metadata(hash: String) -> (byteCount: Int, format: String)? {
    guard let url = fileURL(for: hash),
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source)
    else { return nil }
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
    return hex(hasher.finalize())
  }

  private static func isImage(_ source: CGImageSource) -> Bool {
    CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
  }

  private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

  private static func isValid(_ hash: String) -> Bool {
    hash.utf8.count == 64 && hash.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
  }
}

extension CueStore {
  /// 为正文里引用、本机已有文件、还没有记录的图片登记附件记录。必须在写事务内调用。
  func registerImages(in text: String) throws {
    for hash in Set(CueFormat.imageHashes(in: text)) {
      guard try db.first("SELECT 1 FROM attachments WHERE hash = ?", [hash], { _ in true }) == nil,
        let metadata = files.metadata(hash: hash)
      else { continue }
      let now = Date.stamp
      try insert(
        Attachment(
          id: UUID(), hash: hash, byteCount: metadata.byteCount, format: metadata.format, createdAt: now, modifiedAt: now))
    }
  }
}
