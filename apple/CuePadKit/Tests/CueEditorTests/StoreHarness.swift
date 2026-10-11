import CryptoKit
import CueEditor
import Foundation
import Synchronization

/// 目录里放真实文件的内存图片库：CueEditor 只经 `CueImageStore` 协议读写图片。
final class DirectoryImageStore: CueImageStore, Sendable {
    private struct Stored {
        var files: [String: URL] = [:]
        var data: [Data] = []
    }
    private let stored = Mutex(Stored())
    var storedData: [Data] { stored.withLock { $0.data } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cue-editor-tests-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func store(_ data: Data) throws -> String {
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(id)
        try data.write(to: url)
        stored.withLock { $0.files[id] = url; $0.data.append(data) }
        return id
    }

    func store(fileAt url: URL) throws -> String { try store(Data(contentsOf: url)) }

    func fileURL(for id: String) -> URL? { stored.withLock { $0.files[id] } }
}
