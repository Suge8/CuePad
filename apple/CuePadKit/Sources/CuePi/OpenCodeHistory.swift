#if os(macOS)
import CueStore
import CueText
import Foundation

/// OpenCode 会话里的一条消息（`GET /api/session/{id}/message`）。会话不在文件里，在它服务的库里，所以经接口按页读。
struct OpenCodeMessage: Decodable, Sendable {
    var id: String
    var type: String
    var text: String?
    var files: [File]?
    var metadata: OpenCodePrompt.Metadata?
    var content: [Content]?
    var finish: String?
    /// 助手这一步用的模型
    var model: OpenCodeModelRef?
    /// 压缩：`running` / `completed` / `failed`
    var status: String?
    var tokens: OpenCodeTokens?
    /// 助手这一步出错的原因
    var error: OpenCodeFailure?
    var time: Time

    struct Time: Decodable, Sendable {
        var created: Double
        var completed: Double?
    }

    /// 你的消息带的文件：图片是原图的 base64
    struct File: Decodable, Sendable {
        var data: String?
        var mime: String?
    }

    struct Content: Decodable, Sendable {
        var type: String
        var text: String?
        var id: String?
        var name: String?
        /// 工具调用的状态；文字与思考的 `state` 是提供方的私有状态，不解
        var state: ToolState?

        private enum Keys: String, CodingKey { case type, text, id, name, state }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try c.decode(String.self, forKey: .type)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            state = type == "tool" ? try c.decodeIfPresent(ToolState.self, forKey: .state) : nil
        }
    }

    struct ToolState: Decodable, Sendable {
        var status: String
        var input: OpenCodeToolInput?
    }

    /// 在会话里的先后：消息 id 是 `msg_` 加按时间递增的 12 位十六进制（服务按它排序），重读不变。
    var seq: Int64 { Int64(id.dropFirst(4).prefix(12), radix: 16) ?? 0 }

    var at: Date { Date(timeIntervalSince1970: time.created / 1000) }

    /// 还在写的（助手这一步没完、压缩还在跑）不读：读到它为止，下次从它重读。
    var isComplete: Bool {
        switch type {
        case "assistant": time.completed != nil
        case "compaction": status != "running"
        default: true
        }
    }
}

/// OpenCode 会话的对话与摘要：消息逐条解码进与 Pi 会话文件同一个检查点与对话模型（`PiHistoryCheckpoint`、`PiHistory.Transcript`），
/// 轮次、摘要与工具活动的规则与各家同一处（`PiHistoryCheckpoint` 的 `said`、`answered`……）。这里与 Pi 不同的只有：
/// - 你的消息是 `user`，文字在前、图片（`files` 里的原图）随后各占一行；CuePad 发的那条在 `metadata.cuepadDelivery` 里带着投送请求 id。
/// - 助手的一步是一条 `assistant`：`finish` 为 `tool-calls` 的只累计工具，其余结束一轮；工具的成败就在同一条里（`state.status`）。
/// - 压缩完成是一条 `compaction`（系统行）；`idle` 标记一轮彻底结束（被停止、出错时没有最后的回答）。
/// - 你在终端里直接跑的命令（`shell`）、系统与合成消息、切模型与切 agent 的记录不进对话（终端的对话里它们不是谁说的话）。
enum OpenCodeHistory {
    /// 检查点：Pi 的那份，加读到的最后一条消息（之后只读比它新的）。
    struct Checkpoint: Codable, Sendable {
        var last: String?
        var history = PiHistoryCheckpoint()
    }

    private static let pageSize = 100

    /// 从 `checkpoint` 往后读完这个会话现有的消息；`files` 是你的消息里的图片存进的附件目录。
    @concurrent static func read(
        _ client: OpenCodeClient, _ info: OpenCodeSessionInfo, from checkpoint: Checkpoint?, files: AttachmentFiles
    ) async throws -> (checkpoint: Checkpoint, transcript: PiTranscript) {
        var next = checkpoint ?? Checkpoint()
        next.history.sessionID = info.id
        next.history.cwd = info.location.directory
        var transcript = PiHistory.Transcript(fallbackID: info.id, files: files)
        for message in try await messages(client, session: info.id, after: next.last) {
            guard message.isComplete else { break }
            try ingest(message, &next.history, &transcript)
            next.last = message.id
        }
        return (next, PiTranscript(sessionID: info.id, messages: transcript.messages, recap: next.history.recap))
    }

    /// 比 `after` 新的消息，从早到晚。接口从新到旧分页，读到 `after` 就停。
    @concurrent private static func messages(_ client: OpenCodeClient, session: String, after: String?) async throws -> [OpenCodeMessage] {
        var newer: [OpenCodeMessage] = []
        var cursor: String?
        repeat {
            let query = "limit=\(pageSize)" + (cursor.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? "")
            let page = try await client.get(OpenCodePage<OpenCodeMessage>.self, "/api/session/\(session)/message?\(query)")
            for message in page.data {
                if let after, message.id <= after { return newer.reversed() }
                newer.append(message)
            }
            cursor = page.data.isEmpty ? nil : page.cursor?.next
        } while cursor != nil
        return newer.reversed()
    }

    static func ingest(_ message: OpenCodeMessage, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq = message.seq
        cp.lastActivity = message.at
        let entry = PiHistory.Entry(id: message.id, seq: message.seq, at: message.at)
        switch message.type {
        case "user":
            var said = transcript.said()
            said.text(message.text)
            for file in message.files ?? [] where file.mime?.hasPrefix("image/") == true {
                try said.image(file.data.flatMap { Data(base64Encoded: $0) })
            }
            cp.said(said, entry, deliveryID: message.metadata?.cuepadDelivery, into: &transcript)
        case "assistant":
            for tool in message.content ?? [] where tool.type == "tool" {
                let id = tool.id ?? ""
                cp.toolStarted(id: id, name: tool.name ?? "", arguments: tool.state?.input?.arguments ?? PiToolArguments())
                if let status = tool.state?.status, status == "completed" || status == "error" { cp.toolFinished(id: id, failed: status == "error") }
            }
            guard message.finish != "tool-calls" else { return }
            cp.answered((message.content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n"), entry, into: &transcript)
        case "compaction" where message.status == "completed":
            cp.compacted(entry, into: &transcript)
        case "idle":
            // 一轮彻底结束；还没有回答就结束的（被停止、出错）是没做完的一轮
            if cp.round != nil { cp.interrupted() }
        default: break
        }
    }
}
#endif
