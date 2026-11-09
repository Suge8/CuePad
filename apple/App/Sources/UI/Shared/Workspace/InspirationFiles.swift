import Foundation
import OSLog

/// 准备取消时随所有者释放回收；交给系统后由完成/取消回调回收，不能随准备面板消失而删除。
/// SwiftUI 可能保留上一次更新的值，系统消费结束后不依赖这些旧值何时释放。
nonisolated final class InspirationFiles: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "inspiration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DebugHooks.inspirationFileEvent(directory, created: true)
    }

    deinit { remove() }

    func remove() {
        do {
            try FileManager.default.removeItem(at: directory)
            DebugHooks.inspirationFileEvent(directory, created: false)
        }
        catch CocoaError.fileNoSuchFile { }
        catch { Logger(subsystem: "CuePad", category: "InspirationShare").error("分享临时文件清理失败：\(error.localizedDescription)") }
    }
}

struct InspirationPayload {
    let files: InspirationFiles?
    let urls: [URL]
    var text: String?
    var items: [Any] { text.map { [$0] } ?? urls.map { $0 as Any } }
}
