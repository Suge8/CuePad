#if os(macOS)
import Foundation
import Synchronization

nonisolated struct SessionFile: Sendable {
    let url: URL
    let sessionID: String
    let cwd: String

    private static let writing = Mutex(())
    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    func user(_ text: String, images: [[String: Any]] = [], delivery: String? = nil, at date: Date = .now) throws {
        var message: [String: Any] = [
            "role": "user", "content": [["type": "text", "text": text]] + images.map { $0.merging(["type": "image"]) { _, new in new } },
        ]
        if let delivery { message["cuepadDelivery"] = delivery }
        try append(message, at: date)
    }

    func reply(_ text: String, at date: Date = .now) throws {
        try append(["role": "assistant", "stopReason": "stop", "content": [["type": "text", "text": text]]], at: date)
    }

    func spoke(_ text: String, at date: Date = .now) throws {
        try append(["role": "assistant", "stopReason": "toolUse", "content": [["type": "text", "text": text]]], at: date)
    }

    func tool(_ name: String, id: String, arguments: [String: Any], images: [Data] = [], at date: Date = .now) throws {
        try append(["role": "assistant", "stopReason": "toolUse", "content": [["type": "toolCall", "id": id, "name": name, "arguments": arguments]]], at: date)
        let blocks: [[String: Any]] = [["type": "text", "text": "Read image file [image/png]"]]
            + images.map { ["type": "image", "data": $0.base64EncodedString(), "mimeType": "image/png"] }
        try append(["role": "toolResult", "toolCallId": id, "toolName": name, "content": blocks, "isError": false], at: date)
    }

    func reset() throws {
        let header = try Self.line(["type": "session", "version": 3, "id": sessionID, "timestamp": Self.stamp.format(.now), "cwd": cwd])
        try Self.writing.withLock { _ in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try header.write(to: url)
        }
    }

    private func append(_ message: [String: Any], at date: Date) throws {
        let time = Self.stamp.format(date)
        let entry = try Self.line(["type": "message", "id": UUID().uuidString, "timestamp": time, "message": message])
        try Self.writing.withLock { _ in
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.line(["type": "session", "version": 3, "id": sessionID, "timestamp": time, "cwd": cwd]).write(to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: entry)
        }
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
    }
}
#endif
