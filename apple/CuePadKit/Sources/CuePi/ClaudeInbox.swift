#if os(macOS)
import Darwin
import Foundation

/// Claude Code 会话的收件箱（跨会话消息的 Unix socket，2.1.224 起，官方文档化）：连上、写几行、关掉。它不回话。
/// 第一行可以是认证行 `{"type": "auth", "token": …}`（官方给"脚本往自己会话里投递"的路）：macOS 上不要求，但带上了，
/// 跳过权限确认的会话才直接收下，不挂起等你批准。消息体的格式（`{"type": "user" | "control", …}`）官方没有写，来自实测。
enum ClaudeInbox {
    static let userNote = "（这句是用户本人在 CuePad 里发给你的，不是别的会话：直接在本会话里回答，不需要回传。）\n"

    @concurrent static func post(_ lines: Data, to path: String) async throws {
        guard let fd = try? UnixSocket.connect(path) else { throw PiBridgeError.sessionEnded }
        defer { close(fd) }
        guard writeAll(fd, lines) else { throw PiBridgeError.sessionEnded }
        shutdown(fd, SHUT_WR)
    }
}
#endif
