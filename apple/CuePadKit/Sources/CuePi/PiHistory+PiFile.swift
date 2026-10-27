#if os(macOS)
import CueStore
import CueText
import Foundation

extension PiHistory {
    private struct Line: Decodable {
        var type: String
        var id: String?
        var parentId: String?
        var timestamp: String?
        var cwd: String?
        var name: String?
        var message: Message?
        /// 扩展投进会话的消息（type 为 custom_message）：正文与它在 Pi 的界面上显不显示
        var content: Content?
        var display: Bool?

        var time: Date? { timestamp.flatMap { try? Date($0, strategy: PiHistory.timestampStyle) } }
    }

    private struct Message: Decodable {
        var role: String
        var content: Content?
        var stopReason: String?
        var errorMessage: String?
        var cuepadDelivery: String?
        /// 工具结果（role 为 toolResult）：快速路径认不出键序时由完整解码取这两项
        var toolCallId: String?
        var isError: Bool?
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        struct Block: Decodable {
            var type: String
            var text: String?
            /// 图片（type 为 image）：base64 原字节。不解码成 Data：别的块里若有同名字段，整行就解不开了
            var data: String?
            /// 工具调用（type 为 toolCall）
            var id: String?
            var name: String?
            var arguments: PiToolArguments?
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
        }

        /// 回答：文字块用换行连接
        var reply: String {
            switch self {
            case .text(let s): s
            case .blocks(let b): b.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            }
        }

        var toolCalls: [Block] {
            guard case .blocks(let b) = self else { return [] }
            return b.filter { $0.type == "toolCall" }
        }

        /// 你说的一句（`files` 为 nil 时不存图片）。
        func said(into said: inout Said) throws {
            switch self {
            case .text(let s): said.text(s)
            case .blocks(let blocks):
                for block in blocks {
                    switch block.type {
                    case "text": said.text(block.text)
                    case "image": try said.image(block.data.flatMap { Data(base64Encoded: $0) })
                    default: break
                    }
                }
            }
        }
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// toolResult 行占会话体积的绝大部分（工具输出、图片），摘要只要其中的两样（哪个调用、成没成）：先按 Pi 现在写出的键序
    /// 在两头取，不做 JSON 解码——行首依次是 type, id, parentId, timestamp, message{role, toolCallId, toolName, …}，
    /// 行尾是 …, isError, durationMs, timestamp。两头没找到想要的（键序变了）就不当快速路径处理，落到完整解码，结果不变、只是慢。
    private static let toolResultMarker = Data(#""role":"toolResult""#.utf8)
    private static let toolCallIDMarker = Data(#""toolCallId":""#.utf8)
    private static let failedMarker = Data(#""isError":true"#.utf8)
    private static let succeededMarker = Data(#""isError":false"#.utf8)
    private static let headLength = 512
    private static let tailLength = 128

    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout Transcript) throws {
        cp.seq += 1
        if let result = toolResult(raw) {
            cp.toolFinished(id: result.id, failed: result.failed)
            return
        }
        guard let line = decode(raw) else { return } // 损坏行跳过
        let time = line.time
        // 最后活动：最后一行的时间（Pi 按时间追加）
        if let time { cp.lastActivity = time }
        let entry = Entry(id: line.id ?? "\(cp.seq)", seq: cp.seq, at: time ?? cp.lastActivity ?? .distantPast)
        switch line.type {
        case "session":
            cp.sessionID = line.id
            cp.cwd = line.cwd
        case "session_info":
            cp.name = line.name
        case "compaction":
            cp.compacted(entry, into: &transcript)
        case "custom_message":
            // 扩展投进来、在 Pi 里显示的（FireCode 交回子代理结果、审查结论……）；不显示的是只给模型看的上下文，这里也不进
            guard line.display == true, let text = line.content?.reply.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            cp.machine(text, entry, into: &transcript)
        case "message":
            guard let message = line.message else { return }
            switch message.role {
            case "user":
                var said = transcript.said()
                try message.content?.said(into: &said)
                cp.said(said, entry, deliveryID: message.cuepadDelivery, into: &transcript)
            case "assistant":
                for call in message.content?.toolCalls ?? [] {
                    cp.toolStarted(id: call.id ?? "", name: call.name ?? "", arguments: call.arguments ?? PiToolArguments())
                }
                // 中途调工具前说的一段也是说的话（这一句的回答是最后一段）；被停下（Esc）时说了一半的也是
                switch message.stopReason {
                case "toolUse": cp.spoke(message.content?.reply ?? "", entry)
                case "aborted": cp.interrupted(entry, said: message.content?.reply ?? "", into: &transcript)
                case "error" where message.errorMessage.map(abortMessages.contains) == true:
                    cp.interrupted(entry, said: message.content?.reply ?? "", into: &transcript)
                default: cp.answered(message.content?.reply ?? "", entry, into: &transcript)
                }
            case "toolResult":
                if let id = message.toolCallId { cp.toolFinished(id: id, failed: message.isError == true) }
            default: break
            }
        default:
            break
        }
    }

    /// 中止信号触发的错误（`AbortError`）的原文：Pi 只在请求自己的中止信号触发时记 `aborted`，工具被停下后接着的那次请求、
    /// 别的信号中止的请求失败时记成 `error`（Pi 1.3 实测：在跑时停下或发来新的一句，常是这样），这一轮其实是被停下的。
    /// 原文按出处核对：Node 的 `AbortError` 与 Pi 的 `abortReason`（"The operation was aborted"）、undici 与 node-fetch
    /// （带句号）、`DOMException` 缺省（"This operation was aborted"）、Pi 各提供方与 OpenAI / Anthropic SDK 的
    /// `APIUserAbortError`（"Request was aborted"，SDK 带句号）、Pi 重试等待被中止（"Request aborted"）。
    private static let abortMessages: Set<String> = [
        "The operation was aborted", "The operation was aborted.", "This operation was aborted",
        "Request was aborted", "Request was aborted.", "Request aborted",
    ]

    private static let decoder = JSONDecoder()

    private static func decode(_ raw: UnsafeRawBufferPointer) -> Line? {
        guard let data = raw.borrowedData else { return nil }
        return try? decoder.decode(Line.self, from: data)
    }

    private static func contains(_ raw: UnsafeRawBufferPointer, _ marker: Data) -> Bool {
        guard let base = raw.baseAddress, !raw.isEmpty else { return false }
        return marker.withUnsafeBytes { memmem(base, raw.count, $0.baseAddress, $0.count) != nil }
    }

    private static func head(_ raw: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: raw.prefix(headLength))
    }

    private static func isToolResult(_ raw: UnsafeRawBufferPointer) -> Bool {
        contains(head(raw), toolResultMarker)
    }

    /// 快速路径：工具结果行里的调用 id 与成败；不是工具结果行、或两头没有预期的键为 nil。
    private static func toolResult(_ raw: UnsafeRawBufferPointer) -> (id: String, failed: Bool)? {
        let head = head(raw)
        let tail = UnsafeRawBufferPointer(rebasing: raw.suffix(tailLength))
        guard isToolResult(raw), let base = head.baseAddress, contains(tail, failedMarker) || contains(tail, succeededMarker),
              let hit = toolCallIDMarker.withUnsafeBytes({ memmem(base, head.count, $0.baseAddress, $0.count) })
        else { return nil }
        let start = base.distance(to: UnsafeRawPointer(hit)) + toolCallIDMarker.count
        guard let end = head[start...].firstIndex(of: 0x22) else { return nil }
        return (String(decoding: head[start..<end], as: UTF8.self), contains(tail, failedMarker))
    }
}
#endif
