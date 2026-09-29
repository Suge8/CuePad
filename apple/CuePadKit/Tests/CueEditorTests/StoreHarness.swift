import CryptoKit
import CueEditor
import Foundation

/// 目录里放真实文件的内存图片库：CueEditor 只经 `CueImageStore` 协议读写图片。
final class DirectoryImageStore: CueImageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: URL] = [:]
    private(set) var storedData: [Data] = []
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cue-editor-tests-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func store(_ data: Data) throws -> String {
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(id)
        try data.write(to: url)
        lock.withLock { files[id] = url; storedData.append(data) }
        return id
    }

    func store(fileAt url: URL) throws -> String { try store(Data(contentsOf: url)) }

    func fileURL(for id: String) -> URL? { lock.withLock { files[id] } }
}
