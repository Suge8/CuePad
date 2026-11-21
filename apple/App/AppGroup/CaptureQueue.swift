import CueStore
import Foundation

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

    static func pending(in queue: URL, now: Date = .now) -> (entries: [Entry], unreadable: [String]) {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(at: queue, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var entries: [Entry] = []
        var unreadable: [String] = []
        for directory in directories {
            let manifest = directory.appending(path: manifestName)
            guard fileManager.fileExists(atPath: manifest.path) else {
                let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(modified) > abandonedAfter { try? fileManager.removeItem(at: directory) }
                continue
            }
            do {
                entries.append(Entry(directory: directory, capture: try decoder.decode(PendingCapture.self, from: Data(contentsOf: manifest))))
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
        return (entries.sorted { $0.capture.createdAt < $1.capture.createdAt }, unreadable)
    }

    static let unreadableName = "CaptureUnreadable"
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
