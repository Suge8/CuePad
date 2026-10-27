import Foundation

/// 要放进正文或输入框的一个附件：拖入、粘贴、选来的文件按文件给（边读边算哈希、直接拷，不整个读进内存），截图、浏览器复制的图、
/// 相册的照片按字节给。
public enum IncomingFile: Sendable {
    case file(URL)
    case data(Data)

    /// 存进附件目录，返回键与显示的文件名（字节没有名字）。在后台调用：大文件要读一遍算哈希。
    public func store(in files: any CueFileStore) throws -> (key: String, name: String) {
        switch self {
        case .file(let url): (try files.store(fileAt: url), url.lastPathComponent)
        case .data(let data): (try files.store(data), "")
        }
    }
}
