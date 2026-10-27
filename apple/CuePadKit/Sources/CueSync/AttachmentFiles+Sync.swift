import CueStore
import Foundation

/// 文件那一路对附件目录的用法，按附件的 key（内容哈希，有扩展名时接 "." + 扩展名）。
/// 过渡：附件目录还按哈希放文件，`AttachmentFiles` 换成按 key 的接口后这几条直接用它的，这个文件删掉。
extension AttachmentFiles {
  /// 附件记录的 key：`format` 是扩展名。
  static func key(hash: String, format: String) -> String { format.isEmpty ? hash : hash + "." + format }

  static func key(of attachment: Attachment) -> String { key(hash: attachment.hash, format: attachment.format) }

  static func hash(of key: String) -> String { String(key.prefix { $0 != "." }) }

  func fileURL(forKey key: String) -> URL? { fileURL(for: Self.hash(of: key)) }

  func adopt(fileAt source: URL, key: String) throws { try adopt(fileAt: source, hash: Self.hash(of: key)) }

  /// 服务器收下了这个文件：本机的保底可以删了。
  func uploaded(_ key: String) {}
}
