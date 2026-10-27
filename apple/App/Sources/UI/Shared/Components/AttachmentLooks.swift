import CueEditor
import SwiftUI

/// 编辑器里附件的样子由这台给（`CueTextView.fileStatus`、`fileIcon`）：说法同 `FileStatus`，跟着附件传输（`AppServices.fileTransfers`）重画——
/// 文件到了换上缩略图与大小、在传时进度往前走。点了还没到的去取（`fetch`），到了也是经这里重画。
@MainActor
enum AttachmentLooks {
    /// 接上编辑器；返回跟着传输重画的任务，编辑器拆掉时由宿主取消。
    static func follow(_ services: AppServices, in view: CueTextView) -> Task<Void, Never> {
        view.fileIcon = { Icon.file(named: $0).platformImage }
        view.fileStatus = { [services] key, name, file in FileStatus.line(name: name, file: file, transfer: services.fileTransfers[key]) }
        return Task { [weak view] in
            for await _ in Observations({ services.fileTransfers }) { view?.refreshAttachments() }
        }
    }

    static func fetch(_ key: String, services: AppServices, onError: @escaping (any Error) -> Void) {
        Task {
            do {
                _ = try await services.fetchFile(key)
            } catch {
                onError(error)
            }
        }
    }
}

extension Workspace {
    /// 把还没到这台的附件文件从 iCloud 取来（点了还没到的文件、图片）；到了界面自己换上（在路上的那一张变了）。
    func fetchFile(_ key: String) { AttachmentLooks.fetch(key, services: services, onError: fail) }
}
