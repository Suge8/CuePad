import Foundation

/// 编辑器读写附件文件的唯一出口，由外部（Store 的附件目录 `AttachmentFiles`）注入，在主线程同步调用。按键存取（`AttachmentKey`：
/// 内容哈希 + 扩展名），键直接写进正文的引用。
public protocol CueFileStore: Sendable {
    /// 存入数据（粘贴的图片等），返回键。
    func store(_ data: Data) throws -> String
    /// 存入文件（拖入、粘贴、选的文件，任意类型）；实现应边读边算哈希、直接拷贝，不整个读进内存。
    func store(fileAt url: URL) throws -> String
    /// 本机那份的位置；不在本机（还没从 iCloud 取来）返回 nil，编辑器显示还没到的样子。
    func fileURL(for key: String) -> URL?
}
