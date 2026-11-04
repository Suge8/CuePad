#if os(macOS)
import Foundation
import Synchronization

/// 替身会话的会话文件：像 Pi 那样逐条追加（v3，每行一个条目，时间戳是条目上的时刻）。Mac 的历史索引读它、把对话与摘要写进库，
/// 本机会话的回复在库里只有索引一个写者：测试只写会话文件，不替 Mac 写库。
/// 假扩展收下 Cue 的话（`RecordingHost`）与剧本写会话说的往同一个文件追加：这个进程里的写入排队，一行写完再写下一行，文件头由建出文件的那一次写。
nonisolated struct SessionFile: Sendable {
    let url: URL
    let sessionID: String
    let cwd: String

    private static let writing = Mutex(())
    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// 用户一方说的一句。`delivery` 是 CuePad 投进来的那句的请求 id（Pi 写成 `cuepadDelivery`）；他在终端里打的没有。
    /// `images` 是桥交来的图片块（mimeType、data）。
    func user(_ text: String, images: [[String: Any]] = [], delivery: String? = nil, at date: Date = .now) throws {
        var message: [String: Any] = [
            "role": "user", "content": [["type": "text", "text": text]] + images.map { $0.merging(["type": "image"]) { _, new in new } },
        ]
        if let delivery { message["cuepadDelivery"] = delivery }
        try append(message, at: date)
    }

    /// 这一轮的回答：说完就收尾（`stopReason` 是 stop）。
    func reply(_ text: String, at date: Date = .now) throws {
        try append(["role": "assistant", "stopReason": "stop", "content": [["type": "text", "text": text]]], at: date)
    }

    /// 说了一段接着调工具（问他的对话框是工具调起来的）：这一轮没收尾，这段话记在这一轮的经过里，不是回答。
    func spoke(_ text: String, at date: Date = .now) throws {
        try append(["role": "assistant", "stopReason": "toolUse", "content": [["type": "text", "text": text]]], at: date)
    }

    private func append(_ message: [String: Any], at date: Date) throws {
        let time = Self.stamp.format(date)
        // 条目 id 像 Pi 那样每条不同（索引按它认消息）
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
