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
        let entry = Entry(id: line.uuid ?? "\(cp.seq)", seq: cp.seq, at: time ?? cp.lastActivity ?? .distantPast)
        switch line.type {
        case "custom-title":
            if let title = line.customTitle { cp.name = title }
        case "system":
            switch line.subtype {
            case "compact_boundary": transcript.add(cp, entryID: entry.id, seq: entry.seq, role: .system, text: "已压缩上下文", at: entry.at)
            case "stop_hook_summary", "turn_duration": if cp.round != nil { finish(text: "", entry, into: &cp, transcript: &transcript) }
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
            guard let message = line.message else { return }
            assistant(message, entry, into: &cp, transcript: &transcript)
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

    private struct Entry {
        var id: String
        var seq: Int64
        var at: Date
    }

    private static func user(_ line: Line, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        guard let content = line.message?.content else { return }
        if case .blocks(let blocks) = content, blocks.contains(where: { $0.type == "tool_result" }) {
            for result in blocks where result.type == "tool_result" {
                cp.round?.tools.finish(id: result.toolUseID ?? "", failed: result.isError == true)
            }
            return
        }
        let peer = line.origin?.kind == "peer"
        guard line.isCompactSummary != true, line.isMeta != true || peer else { return }
        let delivery = peer || line.promptSource == "sdk" ? line.uuid : nil
        try said(content, peer: peer, entry, deliveryID: delivery, into: &cp, transcript: &transcript)
    }

    /// 你说的一句：进对话、成为进行中的提问。命令回显与中断标记不是你说的话；中断标记结束这一轮（没有回答，问答不变）。
    private static func said(
        _ content: Content, peer: Bool, _ entry: Entry, deliveryID: String?, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript
    ) throws {
        var said = try content.said(storing: transcript.files)
        if peer { said = (withoutPeerWrapper(said.text), withoutPeerWrapper(said.stored)) }
        let trimmed = said.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(interruptedMarker) {
            cp.round = nil
            cp.recap.pendingPrompt = nil
            return
        }
        guard !commandEchoPrefixes.contains(where: trimmed.hasPrefix) else { return }
        if cp.firstMessage == nil, !trimmed.isEmpty { cp.firstMessage = String(trimmed.prefix(PiSessionName.firstMessageLimit)) }
        if cp.round?.startedAt == nil { cp.round = .init(startedAt: entry.at, tools: cp.round?.tools ?? PiToolLog()) }
        guard !PiHistory.isMachineMessage(said.text) else { return }
        transcript.add(cp, entryID: entry.id, seq: entry.seq, role: .user, text: said.stored, at: entry.at, deliveryID: deliveryID)
        cp.recap.pendingPrompt = PiHistory.clip(PiHistory.collapsed(said.text), PiRecap.promptLimit)
    }

    private static func assistant(_ message: Message, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) {
        var round = cp.round ?? .init(startedAt: nil)
        guard case .blocks(let blocks) = message.content ?? .blocks([]) else { return }
        for call in blocks where call.type == "tool_use" {
            round.tools.start(id: call.id ?? "", name: call.name ?? "", arguments: call.input ?? PiToolArguments(), cwd: cp.cwd)
        }
        cp.round = round
        let text = blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stop = message.stopReason, stop != "tool_use", !text.isEmpty else { return }
        finish(text: text, entry, into: &cp, transcript: &transcript)
    }

    private static func finish(text: String, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) {
        let round = cp.round ?? .init(startedAt: nil)
        if !text.isEmpty {
            transcript.add(
                cp, entryID: entry.id, seq: entry.seq, role: .pi, text: text, at: entry.at, tools: round.tools.summary(), roundStartedAt: round.startedAt)
        }
        cp.recap = PiRecap(
            lastPrompt: cp.recap.pendingPrompt ?? cp.recap.lastPrompt, lastReply: PiHistory.clip(text, PiRecap.replyLimit), pendingPrompt: nil)
        cp.round = nil
    }

    // MARK: 收件箱送来的话

    /// Claude Code 给收件箱送来的话包的说明（2.1.293）：开头一行与结尾一段固定英文，正文原样夹在中间。
    private static let peerPrefix = "Another Claude session sent a message:\n"
    private static let peerSuffix = "\n\nThis came from another Claude session"

    static func withoutPeerWrapper(_ text: String) -> String {
        guard text.hasPrefix(peerPrefix) else { return text }
        let body = text.dropFirst(peerPrefix.count)
        return String(body.range(of: peerSuffix).map { body[..<$0.lowerBound] } ?? body)
    }

    private static let interruptedMarker = "[Request interrupted by user"
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

            struct Source: Decodable { var data: String? }

            enum CodingKeys: String, CodingKey {
                case type, text, source, id, name, input
                case toolUseID = "tool_use_id"
                case isError = "is_error"
            }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
        }

        /// 你说的一句：`text` 是文字块用换行连接，`stored` 是文字与图片按原顺序拼成的正文格式（`files` 为 nil 时不存图片，等同 `text`）。
        func said(storing files: AttachmentFiles?) throws -> (text: String, stored: String) {
            let blocks: [Block]
            switch self {
            case .text(let s): return (s, s)
            case .blocks(let b): blocks = b
            }
            var texts: [String] = [], pieces: [String] = []
            for block in blocks {
                switch block.type {
                case "text":
                    if let piece = block.text, !piece.isEmpty { texts.append(piece); pieces.append(piece) }
                case "image":
                    guard let files, let data = block.source?.data.flatMap({ Data(base64Encoded: $0) }) else { continue }
                    do { pieces.append(CueFormat.imageMarkup(id: try files.store(data))) } catch CueStoreError.notAnImage { continue }
                default: break
                }
            }
            let text = texts.joined(separator: "\n")
            return (text, files == nil ? text : pieces.joined(separator: "\n"))
        }
    }
}
#endif
