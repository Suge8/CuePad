#if os(macOS)
import CueStore
import CueText
import Foundation

/// CuePad 送进去的话：托管进程的 stream-json 与收件箱 socket 都把投送请求 id 当作这条消息的 `uuid`（插进去的是 `source_uuid`）。
enum ClaudeHistory {
    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq += 1
        guard let data = raw.borrowedData, let line = try? decoder.decode(Line.self, from: data)
        else { return }
        let time = line.timestamp.flatMap { try? Date($0, strategy: timestampStyle) }
        if let time { cp.lastActivity = time }
        if cp.sessionID == nil { cp.sessionID = line.sessionId }
        if cp.cwd == nil { cp.cwd = line.cwd }
        guard line.isSidechain != true else { return }
        let entry = PiHistory.Entry(id: line.uuid ?? "\(cp.seq)", seq: cp.seq, at: time ?? cp.lastActivity ?? .distantPast)
        switch line.type {
        case "custom-title":
            cp.named(line.customTitle, byYou: true)
        case "ai-title":
            cp.named(line.aiTitle, byYou: false)
        case "system":
            switch line.subtype {
            case "compact_boundary": cp.compacted(entry, into: &transcript)
            case "stop_hook_summary": if cp.round != nil { cp.answered("", entry, into: &transcript) }
            // 进程内队友还在跑时，2.1.318 把那一轮的这一行推迟到队友都停下才写，可能落在下一轮中途（停掉队友的那次工具调用之后）。
            // 认它接在哪一行后面（parentUuid），不认时长：等后台结果的一轮按时写的这一行也从更早那一轮的开头量起
            case "turn_duration":
                if let ended = cp.round?.endedBy, ended == line.parentUuid { cp.answered("", entry, into: &transcript) }
            default: break
            }
        case "user":
            try user(line, entry, into: &cp, transcript: &transcript)
        case "attachment":
            guard let attachment = line.attachment, attachment.type == "queued_command", attachment.commandMode ?? "prompt" == "prompt",
                  let prompt = attachment.prompt else { return }
            let delivery = attachment.origin?.kind == "human" ? nil : attachment.sourceUUID
            try said(prompt, peer: attachment.origin?.kind == "peer", entry, deliveryID: delivery, into: &cp, transcript: &transcript)
        case "assistant":
            guard let message = line.message, case .blocks(let blocks) = message.content ?? .blocks([]),
                  message.model != syntheticModel || line.isApiErrorMessage == true else { return }
            for call in blocks where call.type == "tool_use" {
                cp.toolStarted(id: call.id ?? "", name: call.name ?? "", arguments: call.input ?? PiToolArguments())
            }
            let text = blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            if let stop = message.stopReason, stop != "tool_use", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cp.answered(text, entry, into: &transcript)
            } else {
                cp.spoke(text, entry)
                cp.round?.endedBy = message.stopReason.map { $0 != "tool_use" } == true ? entry.id : nil
            }
        default:
            break
        }
    }

    private static func user(_ line: Line, _ entry: PiHistory.Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        guard let content = line.message?.content else { return }
        if case .blocks(let blocks) = content, blocks.contains(where: { $0.type == "tool_result" }) {
            // 你拒绝了要用的工具与停下了在跑的工具，Claude Code 写的一样（同一句拒绝、`toolDenialKind: user-rejected`，2.1.299 实测），
            // 分不出来：都照停下处理，不写"已拒绝"
            for result in blocks where result.type == "tool_result" {
                cp.toolFinished(id: result.toolUseID ?? "", failed: result.isError == true, images: try transcript.toolImages(result.content?.images ?? []))
            }
            return
        }
        let peer = line.origin?.kind == "peer"
        guard line.isCompactSummary != true, line.isMeta != true || peer else { return }
        let delivery = peer || line.promptSource == "sdk" ? line.uuid : nil
        try said(content, peer: peer, entry, deliveryID: delivery, into: &cp, transcript: &transcript)
    }

    private static func said(
        _ content: Content, peer: Bool, _ entry: PiHistory.Entry, deliveryID: String?, into cp: inout PiHistoryCheckpoint,
        transcript: inout PiHistory.Transcript
    ) throws {
        var said = transcript.said()
        try content.said(into: &said, peer: peer)
        let trimmed = said.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(interruptedMarker) { return cp.interrupted(entry, into: &transcript) }
        guard !commandEchoPrefixes.contains(where: trimmed.hasPrefix) else { return }
        cp.said(said, entry, deliveryID: deliveryID, into: &transcript)
    }

    /// Claude Code 给收件箱送来的话包的说明（2.1.293）：开头一行与结尾一段固定英文，正文原样夹在中间；CuePad 发的正文前还有一句
    /// `ClaudeInbox.userNote`。钩子交来的那句不一定包着英文说明，说明与那句各自有就去掉。
    private static let peerPrefix = "Another Claude session sent a message:\n"
    private static let peerSuffix = "\n\nThis came from another Claude session"

    static func withoutPeerWrapper(_ text: String) -> String {
        var body = Substring(text)
        if body.hasPrefix(peerPrefix) {
            body = body.dropFirst(peerPrefix.count)
            body = body.range(of: peerSuffix).map { body[..<$0.lowerBound] } ?? body
        }
        if body.hasPrefix(ClaudeInbox.userNote) { body = body.dropFirst(ClaudeInbox.userNote.count) }
        return String(body)
    }

    private static let interruptedMarker = "[Request interrupted by user"
    /// Claude Code 自己补写的助手消息的模型（不是模型说的）：接着被停下的那一轮时补的"No response requested."等不算回答，
    /// 只留出错的（`isApiErrorMessage`，"API Error: …"、额度用完）
    private static let syntheticModel = "<synthetic>"
    private static let commandEchoPrefixes = ["<command-name>", "<command-message>", "<local-command-", "<bash-input>", "<bash-stdout>", "<bash-stderr>"]

    private static let decoder = JSONDecoder()
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private struct Line: Decodable {
        var type: String
        var subtype: String?
        var uuid: String?
        var parentUuid: String?
        var timestamp: String?
        var sessionId: String?
        var cwd: String?
        var isSidechain: Bool?
        var isMeta: Bool?
        var isCompactSummary: Bool?
        var isApiErrorMessage: Bool?
        var customTitle: String?
        var aiTitle: String?
        var promptSource: String?
        var origin: Origin?
        var message: Message?
        var attachment: Attachment?
    }

    private struct Origin: Decodable { var kind: String? }

    private struct Message: Decodable {
        var content: Content?
        var model: String?
        var stopReason: String?
        enum CodingKeys: String, CodingKey {
            case content, model
            case stopReason = "stop_reason"
        }
    }

    private struct Attachment: Decodable {
        var type: String
        var prompt: Content?
        var sourceUUID: String?
        var commandMode: String?
        var origin: Origin?
        enum CodingKeys: String, CodingKey {
            case type, prompt, commandMode, origin
            case sourceUUID = "source_uuid"
        }
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        struct Block: Decodable {
            var type: String
            var text: String?
            var source: Source?
            var id: String?
            var name: String?
            var input: PiToolArguments?
            var toolUseID: String?
            var isError: Bool?
            var content: Content?

            struct Source: Decodable { var data: String? }

            enum CodingKeys: String, CodingKey {
                case type, text, source, id, name, input, content
                case toolUseID = "tool_use_id"
                case isError = "is_error"
            }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
        }

        var images: [Data?] {
            guard case .blocks(let blocks) = self else { return [] }
            return blocks.filter { $0.type == "image" }.map { $0.source?.data.flatMap { Data(base64Encoded: $0) } }
        }

        var plainText: String {
            switch self {
            case .text(let s): s
            case .blocks(let blocks): blocks.compactMap(\.text).joined(separator: "\n")
            }
        }

        func said(into said: inout PiHistory.Said, peer: Bool) throws {
            func text(_ s: String?) { said.text(peer ? s.map(ClaudeHistory.withoutPeerWrapper) : s) }
            switch self {
            case .text(let s): text(s)
            case .blocks(let blocks):
                for block in blocks {
                    switch block.type {
                    case "text": text(block.text)
                    case "image": try said.image(block.source?.data.flatMap { Data(base64Encoded: $0) })
                    default: break
                    }
                }
            }
        }
    }
}
#endif
