import CryptoKit
import CueEditor
import Foundation
import Synchronization

/// 目录里放真实文件的内存图片库：CueEditor 只经 `CueFileStore` 协议读写图片。
final class DirectoryImageStore: CueFileStore, Sendable {
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

    /// 键与附件的键同形（`AttachmentKey`）：哈希接扩展名。
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

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 分片预布局走到了文末：每一段都已真正排好，不再是估算高度。
@MainActor
func laidOutToTheEnd(_ layout: NSTextLayoutManager) -> Bool {
    var done = true
    layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
        done = fragment.state == .layoutAvailable
        return done
    }
    return done
}
