import CueEditor
import CueStore
import SwiftUI

@MainActor
enum AttachmentLooks {
    static func awayLine(_ key: String, _ services: AppServices) -> String {
        FileStatus.line(name: "", file: nil, transfer: services.syncing.fileTransfers[key]).detail
    }

    static func follow(_ services: AppServices, in view: CueTextView) -> Task<Void, Never> {
        view.fileIcon = { Icon.file(named: $0).platformImage }
        view.fileStatus = { [services] key, name, file in FileStatus.line(name: name, file: file, transfer: services.syncing.fileTransfers[key]) }
        return Task { [weak view] in
            for await _ in Observations({ services.syncing.fileTransfers }) { view?.refreshAttachments() }
        }
    }
}

extension Workspace {
    func fetchFile(_ key: String) { attempt { _ = try await self.services.syncing.fetchFile(key) } }

    func openAttachment(_ file: DraftFile, among files: [DraftFile] = [], group: String, with opener: PreviewOpener?) {
        let store = services.store.files, files = files.isEmpty ? [file] : files
        guard store.fileURL(for: file.key) != nil else { return fetchFile(file.key) }
        let batch = files.filter { $0 == file || store.fileURL(for: $0.key) != nil }.compactMap(PreviewItem.init(attachment:))
        guard let opened = batch.first(where: { $0.key == file.key }) else { return }
        let opening = PreviewOpening(preview: opened, batch: batch, group: group)
        if let opener { return opener(opening) }
        preview = opening
        #if os(macOS)
        services.windowShell?.show()
        #endif
    }
}

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
        content.task(id: Run(key: key, moving: services.syncing.fileTransfers[key] != nil)) {
            place = await Self.place(of: key, in: services.store.files)
        }
    }

    @concurrent private static func place(of key: String, in files: AttachmentFiles) async -> AttachmentPlace {
        files.fileURL(for: key).map(AttachmentPlace.here) ?? .away
    }
}
