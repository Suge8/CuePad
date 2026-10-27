import Foundation
import UniformTypeIdentifiers

/// 要放进正文或输入框的一个附件：拖入、选来的文件按文件给（边读边算哈希、直接拷，不整个读进内存），截图、浏览器复制的图、
/// 相册的照片按字节给；手机上粘贴、拖入的条目按条目给（`pasted`，取出来时才存）。
public enum IncomingFile: Sendable {
    case file(URL)
    case data(Data)
    #if canImport(UIKit)
    /// 手机上粘贴、拖入的一个条目（`PastedItem.isFile` 认出是附件的）
    case pasted(PastedItem)
    #endif

    /// 存进附件目录，返回键与显示的文件名（字节没有名字）。在后台调用：大文件要读一遍算哈希。
    /// 选择器、文件 App 给的带安全作用域的文件在这里拿访问权、存好就放开；别的文件拿不到也照常读。
    public func store(in files: any CueFileStore) async throws -> (key: String, name: String) {
        switch self {
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (try files.store(fileAt: url), url.lastPathComponent)
        case .data(let data): return (try files.store(data), "")
        #if canImport(UIKit)
        case .pasted(let item): return try await item.store(in: files)
        #endif
        }
    }
}
