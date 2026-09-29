import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片文件：按内容哈希（SHA-256 十六进制）存放在 store 所在目录旁的 `Attachments/`，文件名就是哈希。
/// 缩略图是派生数据，每次按需从原图生成，不落盘、不入库、不同步。
public struct AttachmentFiles: Sendable {
  let directory: URL

  /// 原图字节。哈希来自卡片正文，格式不合法或文件不存在都是 notFound（不会越出附件目录）。
  public func original(hash: String) throws -> Data {
    guard Self.isValid(hash), let data = try? Data(contentsOf: directory.appending(path: hash)) else {
      throw CueStoreError.notFound
    }
    return data
  }

  /// 最长边不超过 `maxPixel` 的缩略图（已按 EXIF 方向校正，不放大）。
  public func thumbnail(hash: String, maxPixel: Int) throws -> CGImage {
    guard Self.isValid(hash) else { throw CueStoreError.notFound }
    let url = directory.appending(path: hash)
    guard FileManager.default.fileExists(atPath: url.path),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    else { throw CueStoreError.notFound }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw CueStoreError.notAnImage
    }
    return image
  }

  /// 校验是图片后按哈希落盘；已有同哈希文件则不重写。返回哈希与格式（文件扩展名，如 png、jpeg）。
  func write(_ data: Data) throws -> (hash: String, format: String) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let identifier = CGImageSourceGetType(source),
      let format = UTType(identifier as String)?.preferredFilenameExtension,
      CGImageSourceGetCount(source) > 0
    else { throw CueStoreError.notAnImage }

    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let url = directory.appending(path: hash)
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    }
    return (hash, format)
  }

  private static func isValid(_ hash: String) -> Bool {
    hash.utf8.count == 64 && hash.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
  }
}

extension CueStore {
  /// 存入一张图片：校验、按内容哈希去重落盘，并登记附件元数据；返回的哈希用于正文里的 `cuepad://img/<哈希>`。
  /// 先写文件再登记，中途失败只会留下可复用的文件，不会有指向缺失文件的记录。
  @discardableResult
  public func addImage(_ data: Data) throws -> Attachment {
    let stored = try files.write(data)
    return try registerAttachment(hash: stored.hash, byteCount: data.count, format: stored.format)
  }
}
