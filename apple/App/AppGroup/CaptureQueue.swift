import CueStore
import Foundation

/// 分享扩展收到的内容。文件（图片也是）是扩展拷到自己临时目录的那份与显示的文件名。
nonisolated struct ShareContent: Equatable, Sendable {
    struct File: Equatable, Sendable {
        var url: URL
        var name: String
    }

    var text: String?
    var urls: [URL] = []
    var files: [File] = []

    var isEmpty: Bool { (text?.isEmpty ?? true) && urls.isEmpty && files.isEmpty }
}

/// 待入库的一条分享。文件放在同一目录（`stored` 是其中的文件名，`name` 是显示的文件名）。
nonisolated struct PendingCapture: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var stored: String
        var name: String
    }

    var text: String?
    var urls: [URL]
    var files: [File]
    var project: UUID
    var createdAt: Date
}

/// 分享扩展与主 App 之间的数据通路：扩展只往容器里的 `Capture/` 放内容，由主 App 入库，
/// 资料库始终只有主 App 一个写者，主 App 的界面订阅也照常触发。
/// 每条是一个目录：先放文件，最后原子写 `capture.json`；没有 json 的目录是尚未写完的，读取时跳过。
nonisolated enum CaptureQueue {
    /// 扩展写完后发出的进程间通知，主 App 收到后入库。
    static let notification = "\(AppIdentity.id).capture-enqueued"

    private static let manifestName = "capture.json"

    struct Entry: Sendable {
        let directory: URL
        let capture: PendingCapture

        /// 这条带的文件：条目目录里的那份与显示的文件名。
        func files() -> [(url: URL, name: String)] { capture.files.map { (directory.appending(path: $0.stored), $0.name) } }
    }

    static func enqueue(_ content: ShareContent, project: UUID, into queue: URL, now: Date = .now) throws {
        let directory = queue.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [PendingCapture.File] = []
        for (index, file) in content.files.enumerated() {
            let ext = file.url.pathExtension
            let stored = "file-\(index + 1)" + (ext.isEmpty ? "" : "." + ext)
            try FileManager.default.copyItem(at: file.url, to: directory.appending(path: stored))
            files.append(PendingCapture.File(stored: stored, name: file.name))
        }
        let capture = PendingCapture(text: content.text, urls: content.urls, files: files, project: project, createdAt: now)
        try encoder.encode(capture).write(to: directory.appending(path: manifestName), options: .atomic)
    }

    static func pending(in queue: URL) -> [Entry] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { directory -> Entry? in
            guard let data = try? Data(contentsOf: directory.appending(path: manifestName)),
                  let capture = try? decoder.decode(PendingCapture.self, from: data)
            else { return nil }
            return Entry(directory: directory, capture: capture)
        }.sorted { $0.capture.createdAt < $1.capture.createdAt }
    }

    static func remove(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.directory)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
