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

/// `stored` 是文件在同一目录里的文件名，`name` 是显示的文件名。
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
/// 每条是一个目录：先放文件，最后原子写 `capture.json`；没有 json 的目录是尚未写完的，读取时跳过，放了 `abandonedAfter` 还没写完的是扩展半路没了，收拾时删掉。
/// 目录名（UUID）是条目的稳定标识：入库时与建卡同事务记下（`CueStore.createCard(capture:)`），删失败的条目下次只重试删除。
nonisolated enum CaptureQueue {
    static let notification = "\(AppIdentity.id).capture-enqueued"

    private static let manifestName = "capture.json"

    struct Entry: Sendable {
        let directory: URL
        let capture: PendingCapture
        var id: String { directory.lastPathComponent }

        func files() -> [(url: URL, name: String)] { capture.files.map { (directory.appending(path: $0.stored), $0.name) } }
    }

    static func enqueue(_ content: ShareContent, project: UUID, into queue: URL) throws {
        let directory = queue.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [PendingCapture.File] = []
        for (index, file) in content.files.enumerated() {
            let ext = file.url.pathExtension
            let stored = "file-\(index + 1)" + (ext.isEmpty ? "" : "." + ext)
            try FileManager.default.copyItem(at: file.url, to: directory.appending(path: stored))
            files.append(PendingCapture.File(stored: stored, name: file.name))
        }
        let capture = PendingCapture(text: content.text, urls: content.urls, files: files, project: project, createdAt: .now)
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

    /// 收拾入不了库、也等不到的条目，返回挪走的那几条读不出的原因（调用方报告）：
    /// 清单读不出（文件坏了、别的版本的格式）的整条挪进旁边的 `unreadableName` 目录，不再每次重试、也不丢；没写完又放太久的删掉。
    static func clearUnusable(in queue: URL, now: Date = .now) -> [String] {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(at: queue, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var unreadable: [String] = []
        for directory in directories {
            let manifest = directory.appending(path: manifestName)
            guard fileManager.fileExists(atPath: manifest.path) else {
                let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(modified) > abandonedAfter { try? fileManager.removeItem(at: directory) }
                continue
            }
            do {
                _ = try decoder.decode(PendingCapture.self, from: Data(contentsOf: manifest))
            } catch {
                let aside = queue.deletingLastPathComponent().appending(path: unreadableName, directoryHint: .isDirectory)
                do {
                    try fileManager.createDirectory(at: aside, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: directory, to: aside.appending(path: directory.lastPathComponent))
                    unreadable.append("\(directory.lastPathComponent)：\(error)")
                } catch {
                    unreadable.append("\(directory.lastPathComponent) 读不出也没能挪开：\(error)")
                }
            }
        }
        return unreadable
    }

    static let unreadableName = "CaptureUnreadable"
    /// 扩展写一条最多几秒；放一天还没写完的不会再有人写。
    private static let abandonedAfter: TimeInterval = 86_400

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
