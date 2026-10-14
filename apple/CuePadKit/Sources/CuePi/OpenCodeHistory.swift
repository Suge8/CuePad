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
    /// `idle` 的：这一轮怎么结束的（`succeeded` / `interrupted` / `failed`）
    var outcome: String?
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
        var error: OpenCodeFailure?
    }

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
/// - 压缩完成是一条 `compaction`（系统行）；`idle` 标记一轮彻底结束（被停止、出错时没有最后的回答）；被停下的那一步带 `aborted` 错误。
/// - 你在终端里直接跑的命令（`shell`）、系统与合成消息、切模型与切 agent 的记录不进对话（终端的对话里它们不是谁说的话）。
enum OpenCodeHistory {
    /// 你拒绝了权限确认时工具的出错原因（2.0.29；那一步随之带着 `aborted` 的错误停下）
    static let declinedTool = "The user declined this tool call"

    /// 检查点：Pi 的那份，加读到哪。先后只认消息在对话里的位置：排队的话入队时就拿到了消息 id，送进对话却在后面
    /// （插的话、它前面那轮的回答都排在它前头），所以既不按 id 比"读过没有"，也不拿 id 当 seq。
    struct Checkpoint: Codable, Sendable {
        /// 接口给的游标（不透明），指向读过的最后一条之后；从头读为 nil
        var cursor: String?
        /// 读过几条：下一条消息的位置，也就是它的 seq
        var position: Int64 = 0
        var history = PiHistoryCheckpoint()
    }

    private static let pageSize = 100

    /// 从 `checkpoint` 往后读完这个会话现有的消息（按对话里的先后，从早到晚）；`files` 是你的消息里的图片存进的附件目录。
    /// 读到还没写完的一条就停：游标停在它前一条之后，下次从它重读。
    @concurrent static func read(
        _ client: OpenCodeClient, _ info: OpenCodeSessionInfo, from checkpoint: Checkpoint?, files: AttachmentFiles
    ) async throws -> (checkpoint: Checkpoint, transcript: PiTranscript) {
        var next = checkpoint ?? Checkpoint()
        next.history.sessionID = info.id
        next.history.cwd = info.location.directory
        var transcript = PiHistory.Transcript(fallbackID: info.id, files: files)
        while true {
            let page = try await self.page(client, session: info.id, from: next.cursor, limit: pageSize)
            if let unfinished = page.data.firstIndex(where: { !$0.isComplete }) {
                for message in page.data[..<unfinished] { try ingest(message, at: &next, &transcript) }
                if unfinished > 0 { next.cursor = try await self.page(client, session: info.id, from: next.cursor, limit: unfinished).cursor?.next }
                break
            }
            for message in page.data { try ingest(message, at: &next, &transcript) }
            if let cursor = page.cursor?.next, !page.data.isEmpty { next.cursor = cursor }
            guard page.data.count == pageSize else { break }
        }
        return (next, PiTranscript(sessionID: info.id, messages: transcript.messages, recap: next.history.recap))
    }

    /// `cursor` 之后的一页（从头读时是最早的一页），从早到晚。
    @concurrent private static func page(
        _ client: OpenCodeClient, session: String, from cursor: String?, limit: Int
    ) async throws -> OpenCodePage<OpenCodeMessage> {
        let from = cursor.map { "cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? "order=asc"
        return try await client.get(OpenCodePage<OpenCodeMessage>.self, "/api/session/\(session)/message?limit=\(limit)&\(from)")
    }

    private static func ingest(_ message: OpenCodeMessage, at checkpoint: inout Checkpoint, _ transcript: inout PiHistory.Transcript) throws {
        try ingest(message, seq: checkpoint.position, &checkpoint.history, &transcript)
        checkpoint.position += 1
    }

    static func ingest(_ message: OpenCodeMessage, seq: Int64, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq = seq
        cp.lastActivity = message.at
        let entry = PiHistory.Entry(id: message.id, seq: seq, at: message.at)
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
                if tool.state?.error?.message == Self.declinedTool {
                    cp.toolDeclined(id: id)
                } else if let status = tool.state?.status, status == "completed" || status == "error" {
                    cp.toolFinished(id: id, failed: status == "error")
                }
            }
            // 被停下的那一步带着 `aborted` 的错误（接着的 `idle` 也是 `interrupted`）
            if message.error?.type == "aborted" { return cp.interrupted(entry, into: &transcript) }
            let text = (message.content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            if message.finish == "tool-calls" { cp.spoke(text, entry) } else { cp.answered(text, entry, into: &transcript) }
        case "compaction" where message.status == "completed":
            cp.compacted(entry, into: &transcript)
        case "idle":
            // 一轮彻底结束；还没有回答就结束的：被停下的与各家同一规则，出错的与 Pi 出错一样以空回答结束
            guard cp.round != nil else { return }
            if message.outcome == "interrupted" { cp.interrupted(entry, into: &transcript) } else { cp.answered("", entry, into: &transcript) }
        default: break
        }
    }
}
#endif
