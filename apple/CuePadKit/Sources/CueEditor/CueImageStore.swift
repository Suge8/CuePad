import Foundation

/// 编辑器读写图片的唯一出口，由外部（Store）注入。按内容哈希存取：
/// 相同内容得到相同 id，id 是小写十六进制串，直接写进正文的图片引用。
public protocol CueImageStore: Sendable {
    /// 存入图片数据（PNG 等），返回内容哈希 id。
    func store(_ data: Data) throws -> String
    /// 存入图片文件（拖入），实现应直接拷贝文件，避免整张进内存。
    func store(fileAt url: URL) throws -> String
    /// 原图文件位置；不存在（例如尚未从 iCloud 下载）返回 nil，编辑器显示占位。
    func fileURL(for id: String) -> URL?
}
