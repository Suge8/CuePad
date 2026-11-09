import CueEditor
import CueStore
import SwiftUI

@MainActor
enum AttachmentLooks {
    static func awayLine(_ key: String, _ services: AppServices) -> String {
        FileStatus.line(name: "", file: nil, transfer: services.fileTransfers[key]).detail
    }

    /// 返回跟着传输重画的任务，编辑器拆掉时由宿主取消。
    static func follow(_ services: AppServices, in view: CueTextView) -> Task<Void, Never> {
        view.fileIcon = { Icon.file(named: $0).platformImage }
        view.fileStatus = { [services] key, name, file in FileStatus.line(name: name, file: file, transfer: services.fileTransfers[key]) }
        return Task { [weak view] in
            for await _ in Observations({ services.fileTransfers }) { view?.refreshAttachments() }
        }
    }
}

extension Workspace {
    func fetchFile(_ key: String) { attempt { _ = try await self.services.fetchFile(key) } }

    /// 挂着全屏页的页面给 `opener`（底栏对着这一页说）；没挂的小窗（菜单栏、Cue 条）在主窗口里打开（`preview`）。`files` 空的是只有它自己。
    func openAttachment(_ file: DraftFile, among files: [DraftFile] = [], group: String, with opener: PreviewOpener?) {
        let store = services.store.files, files = files.isEmpty ? [file] : files
        guard store.fileURL(for: file.key) != nil else { return fetchFile(file.key) }
        let batch = files.filter { $0 == file || store.fileURL(for: $0.key) != nil }.compactMap(PiPreview.init(attachment:))
        guard let opened = batch.first(where: { $0.key == file.key }) else { return }
        let opening = PreviewOpening(preview: opened, batch: batch, group: group)
        if let opener { return opener(opening) }
        preview = opening
        #if os(macOS)
        services.windowShell?.show()
        #endif
    }
}

/// 记录随同步先到、文件另走一路后到，手机上大文件点了才取。查到的本机那份随它记着，视图体每次重画（传输进度一变就重画）不再各查一遍文件系统。
enum AttachmentPlace: Equatable {
    case unchecked
    case here(URL)
    case away

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
