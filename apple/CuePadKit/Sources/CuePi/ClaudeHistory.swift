#if os(macOS)
import CueStore
import CueText
import Foundation

/// Claude Code 会话文件（`<配置目录>/projects/<编码后的工作目录>/<会话 id>.jsonl`）的逐行解码，规则与 Pi 的对话、摘要一致（见 `PiHistory`）。
///
/// - 一次模型回答按内容块拆成好几行（同一个 `message.id`）；`stop_reason` 不是 `tool_use` 的那行带着文字时，这一轮做完，
///   它的文字就是 Claude Code 这一轮的回答。没有文字就做完的一轮（只调了工具）在 `stop_hook_summary` / `turn_duration` 收尾。
/// - 你的话：`type: user` 的文字与图片（图片内嵌 base64，存进附件目录）；一轮正在跑时插进去的话不是 user 行，是
///   `queued_command` 附件。工具结果、斜杠命令的回显（`<command-name>`、`<local-command-…>`）、`isMeta` 的提醒不算。
/// - CuePad 送进去的话：托管进程的 stream-json 与收件箱 socket 都把投送请求 id 当作这条消息的 `uuid`（插进去的是 `source_uuid`）；
///   收件箱送来的会被包上"另一个 Claude 会话发来的"英文说明，这里剥掉。终端里直接打的（`origin.kind` 为 `human`）没有投送请求。
/// - 会话名只认 `/rename`（及 CuePad 的改名）写下的 `custom-title`；自动生成的 `ai-title` 不算，与 Pi 的 `/name` 同一层意思。
enum ClaudeHistory {
    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq += 1
        guard let base = raw.baseAddress, !raw.isEmpty,
              let line = try? decoder.decode(Line.self, from: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: raw.count, deallocator: .none))
        else { return }
        let time = line.timestamp.flatMap { try? Date($0, strategy: timestampStyle) }
        if let time { cp.lastActivity = time }
        if cp.sessionID == nil { cp.sessionID = line.sessionId }
        if cp.cwd == nil { cp.cwd = line.cwd }
        guard line.isSidechain != true else { return }
        let entry = PiHistory.Entry(id: line.uuid ?? "\(cp.seq)", seq: cp.seq, at: time ?? cp.lastActivity ?? .distantPast)
        switch line.type {
        case "custom-title":
            if let title = line.customTitle { cp.name = title }
        case "system":
            switch line.subtype {
            case "compact_boundary": cp.compacted(entry, into: &transcript)
            case "stop_hook_summary", "turn_duration": if cp.round != nil { cp.answered("", entry, into: &transcript) }
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
            guard let message = line.message, case .blocks(let blocks) = message.content ?? .blocks([]) else { return }
            for call in blocks where call.type == "tool_use" {
                cp.toolStarted(id: call.id ?? "", name: call.name ?? "", arguments: call.input ?? PiToolArguments())
            }
            let text = blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            // 一次回答拆成好几行：带文字、不是停下来调工具的那行结束这一轮，其余带文字的是中途说的一段
            if let stop = message.stopReason, stop != "tool_use", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cp.answered(text, entry, into: &transcript)
            } else {
                cp.spoke(text, entry)
            }
        default:
            break
        }
    }

    /// 会话名与第一条你的话（发现已在跑的会话时补上）；文件还没落盘为 nil。
    static func summary(of file: URL) -> (name: String?, firstMessage: String?)? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        var cp = PiHistoryCheckpoint()
        var ignored = PiHistory.Transcript(fallbackID: "", files: nil)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var start = 0
            while start < raw.count {
                let end = raw[start...].firstIndex(of: 0x0A) ?? raw.count
                try? ingest(UnsafeRawBufferPointer(rebasing: raw[start..<end]), &cp, &ignored)
                start = end + 1
            }
        }
        return (cp.name, cp.firstMessage)
    }

    private static func user(_ line: Line, _ entry: PiHistory.Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        guard let content = line.message?.content else { return }
        if case .blocks(let blocks) = content, blocks.contains(where: { $0.type == "tool_result" }) {
            for result in blocks where result.type == "tool_result" {
                if result.isError == true, result.content?.plainText.hasPrefix(declinedResult) == true {
                    cp.toolDeclined(id: result.toolUseID ?? "")
                    continue
                }
                cp.toolFinished(id: result.toolUseID ?? "", failed: result.isError == true)
            }
            return
        }
        let peer = line.origin?.kind == "peer"
        guard line.isCompactSummary != true, line.isMeta != true || peer else { return }
        let delivery = peer || line.promptSource == "sdk" ? line.uuid : nil
        try said(content, peer: peer, entry, deliveryID: delivery, into: &cp, transcript: &transcript)
    }

    /// 你说的一句。命令回显不是你说的话；中断标记结束这一轮（没有回答，问答不变）。
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

    // MARK: 收件箱送来的话

    /// Claude Code 给收件箱送来的话包的说明（2.1.293）：开头一行与结尾一段固定英文，正文原样夹在中间；CuePad 发的正文前还有一句
    /// `ClaudeInbox.userNote`。
    private static let peerPrefix = "Another Claude session sent a message:\n"
    private static let peerSuffix = "\n\nThis came from another Claude session"

    static func withoutPeerWrapper(_ text: String) -> String {
        guard text.hasPrefix(peerPrefix) else { return text }
        var body = text.dropFirst(peerPrefix.count)
        if body.hasPrefix(ClaudeInbox.userNote) { body = body.dropFirst(ClaudeInbox.userNote.count) }
        return String(body.range(of: peerSuffix).map { body[..<$0.lowerBound] } ?? body)
    }

    private static let interruptedMarker = "[Request interrupted by user"
    /// 你在终端里对权限确认答"否"时工具结果的开头（2.1.299，后面跟"停下"或你说的怎么做）
    private static let declinedResult = "The user doesn't want to proceed with this tool use."
    /// 斜杠命令与 `!` 命令留下的回显：终端的对话里是命令本身与它的输出，不是你对模型说的话
    private static let commandEchoPrefixes = ["<command-name>", "<command-message>", "<local-command-", "<bash-input>", "<bash-stdout>", "<bash-stderr>"]

    // MARK: 解码

    private static let decoder = JSONDecoder()
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private struct Line: Decodable {
        var type: String
        var subtype: String?
        var uuid: String?
        var timestamp: String?
        var sessionId: String?
        var cwd: String?
        var isSidechain: Bool?
        var isMeta: Bool?
        var isCompactSummary: Bool?
        var customTitle: String?
        var promptSource: String?
        var origin: Origin?
        var message: Message?
        var attachment: Attachment?
    }

    private struct Origin: Decodable { var kind: String? }

    private struct Message: Decodable {
        var content: Content?
        var stopReason: String?
        enum CodingKeys: String, CodingKey {
            case content
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
            /// 工具结果的正文
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

        var plainText: String {
            switch self {
            case .text(let s): s
            case .blocks(let blocks): blocks.compactMap(\.text).joined(separator: "\n")
            }
        }

        /// 你说的一句；收件箱送来的（`peer`）剥掉 Claude Code 包的说明。
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
