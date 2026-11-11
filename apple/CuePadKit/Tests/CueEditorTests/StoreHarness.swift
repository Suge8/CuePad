import CryptoKit
import CueEditor
import Foundation
import Synchronization

/// CueEditor 只经 `CueFileStore` 协议读写附件。
final class DirectoryFileStore: CueFileStore, Sendable {
    private struct Stored {
        var files: [String: URL] = [:]
        var data: [Data] = []
    }
    private let stored = Mutex(Stored())
    var storedData: [Data] { stored.withLock { $0.data } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cue-editor-tests-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func store(_ data: Data) throws -> String { try store(data, format: "png") }

    private func store(_ data: Data, format: String) throws -> String {
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "." + format
        let url = directory.appendingPathComponent(id)
        try data.write(to: url)
        stored.withLock { $0.files[id] = url; $0.data.append(data) }
        return id
    }

    func store(fileAt url: URL) throws -> String { try store(Data(contentsOf: url), format: url.pathExtension.lowercased()) }

    func fileURL(for id: String) -> URL? { stored.withLock { $0.files[id] } }
}
