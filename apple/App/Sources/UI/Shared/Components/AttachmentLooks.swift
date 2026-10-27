import CueEditor
import CueStore
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

/// 附件文件在不在本机（记录随同步先到、文件另走一路后到，手机上大文件点了才取），由 `observingArrival` 查：
/// 查过之前（`unchecked`）按到了画。查到的本机那份随它记着，视图体每次重画（传输进度一变就重画）不再各查一遍文件系统。
enum AttachmentPlace: Equatable {
    case unchecked
    case here(URL)
    case away

    /// 本机那份；还没查过时当场找（出现到第一次查完之间，通常就一帧）。
    func file(_ key: String, in files: AttachmentFiles) -> URL? {
        switch self {
        case .here(let url): url
        case .away: nil
        case .unchecked: files.fileURL(for: key)
        }
    }

    var isAway: Bool { self == .away }
}

extension View {
    /// 出现时与这个文件的一趟传输结束时（在路上的那一张里没了它，`AppServices.fileTransfers`）各查一次附件文件在不在本机。
    /// 行在滚动中一个个出现，不在主线程上查。
    func observingArrival(of key: String, in services: AppServices, into place: Binding<AttachmentPlace>) -> some View {
        modifier(Arrival(key: key, services: services, place: place))
    }
}

private struct Arrival: ViewModifier {
    let key: String
    let services: AppServices
    @Binding var place: AttachmentPlace

    private struct Run: Equatable {
        let key: String
        let moving: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Run(key: key, moving: services.fileTransfers[key] != nil)) {
            place = await Self.place(of: key, in: services.store.files)
        }
    }

    @concurrent private static func place(of key: String, in files: AttachmentFiles) async -> AttachmentPlace {
        files.fileURL(for: key).map(AttachmentPlace.here) ?? .away
    }
}
