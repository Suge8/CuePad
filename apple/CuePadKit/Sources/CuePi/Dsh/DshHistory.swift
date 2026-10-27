#if os(macOS)
import CueStore
import CueText
import Foundation

/// dsh 会话文件（`DshRuntime.sessions` 下的 `<编码后的工作目录>/<会话 id>/session.v4.jsonl`，明文，见 `DshRuntime` 头注释）的逐行解码，
/// 规则与 Pi 的对话、摘要一致（见 `PiHistory`）。
///
/// - 第一行是会话头（`type: session`）：会话 id、工作目录；子代理自己的会话（`delegationDepth` 大于 0）不是会话列表里的会话。
/// - 一行一个事件 `{type, seq, time, data}`：`turn/start` 开始一轮，`turn/end` 结束（`aborted` 是被停下）；`user/message` 里来源是
///   `user` 的是你的话（含一轮在跑时插进去的），子代理交回的结果（`subagent-settled`）是机器消息，运行时上下文等别的来源不算；
///   `assistant/message` 的文字块是说的一段，最后一段在这一轮结束时成为回答；`tool/call`、`tool/result` 记工具活动；
///   `compaction/end` 没出错是压缩；会话名只认来源是 `user` 的 `session/title`（CuePad 的改名），dsh 自己按首句取的不算。
/// - 你的话里的图片是 dsh 附件库里的引用（`<DSH_HOME>/attachments/v1/objects/<前两位>/<sha256>`），按会话文件的位置找到那个 DSH_HOME。
/// - CuePad 送进去的话：插件在它进收件箱时先记一条 `plugin:cuepad/delivery` {message, delivery}（`dsh-cuepad.mjs`），随后那条 `user/message` 按 id 认领。
enum DshHistory {
    static let fileName = "session.v4.jsonl"

    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq += 1
        guard let bytes = raw.borrowedData, let line = try? decoder.decode(Line.self, from: bytes)
        else { return }
        let time = (line.time ?? line.createdAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        if let time { cp.lastActivity = time }
        let at = time ?? cp.lastActivity ?? .distantPast
        let data = line.data
        let entry = PiHistory.Entry(id: data?.id ?? data?.message?.id ?? "\(cp.seq)", seq: cp.seq, at: at)
        switch line.type {
        case "session":
            cp.sessionID = line.id
            cp.cwd = line.cwd
            if (line.delegationDepth ?? 0) > 0 { cp.excluded = true }
        case "turn/start":
            cp.roundStarted(at: at)
        case "turn/end":
            if data?.reason?.kind == "aborted" { cp.interrupted(entry, into: &transcript) } else { cp.answered("", entry, into: &transcript) }
        case "user/message":
            guard let data else { return }
            try said(data, entry, into: &cp, transcript: &transcript)
        case "assistant/message":
            let blocks = data?.message?.content ?? []
            cp.spoke(blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n"), entry)
        case "tool/call":
            guard let id = data?.callId else { return }
            let arguments = data?.arguments.flatMap { try? decoder.decode(PiToolArguments.self, from: Data($0.utf8)) } ?? PiToolArguments()
            cp.toolStarted(id: id, name: data?.name ?? "", arguments: arguments)
        case "tool/result":
            guard let id = data?.message?.toolCallId else { return }
            cp.toolFinished(id: id, failed: data?.message?.isError == true)
        case "compaction/end":
            if data?.error == nil { cp.compacted(entry, into: &transcript) }
        case "session/title":
            if data?.source?.kind == "user", let title = data?.title { cp.name = title }
        case "plugin:cuepad/delivery":
            if let message = data?.messageID, let delivery = data?.delivery { cp.deliveries[message] = delivery }
        default:
            break
        }
    }

    private static func said(_ data: Line.Payload, _ entry: PiHistory.Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        let text = (data.content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        switch data.source?.kind {
        case "user":
            var said = transcript.said()
            for block in data.content ?? [] {
                switch block.type {
                case "text": said.text(block.text)
                case "image": try said.image(block.attachment.flatMap { image($0, near: transcript.file) })
                default: break
                }
            }
            cp.said(said, entry, deliveryID: data.id.flatMap { cp.deliveries.removeValue(forKey: $0) }, into: &transcript)
        case "subagent-settled":
            cp.machine(text, entry, into: &transcript)
        default:
            break
        }
    }

    /// 附件库里的原图：会话文件在 `<DSH_HOME>/<DshRuntime.sessions>/<项目>/<id>/` 下。
    private static func image(_ attachment: Line.Attachment, near file: URL?) -> Data? {
        guard let file, let hash = attachment.attachmentId?.split(separator: ":").last, hash.count > 2 else { return nil }
        var home = file
        for _ in 0..<(DshRuntime.sessions.split(separator: "/").count + 3) { home.deleteLastPathComponent() }
        return try? Data(contentsOf: home.appending(path: "attachments/v1/objects/\(hash.prefix(2))/\(hash)"))
    }

    // MARK: 解码

    private static let decoder = JSONDecoder()

    private struct Line: Decodable {
        var type: String
        var time: Double?
        var data: Payload?
        // 会话头
        var id: String?
        var cwd: String?
        var createdAt: Double?
        var delegationDepth: Int?

        struct Payload: Decodable {
            var id: String?
            var content: [Block]?
            var source: Source?
            var message: Message?
            var reason: Source?
            var callId: String?
            var name: String?
            var arguments: String?
            var error: String?
            var title: String?
            var delivery: String?
            var messageID: String?

            enum CodingKeys: String, CodingKey {
                case id, content, source, message, reason, callId, name, arguments, error, title, delivery
                case messageID = "messageId"
            }

            /// `plugin:cuepad/delivery` 的 `message` 是消息 id 字符串，别的事件的 `message` 是消息对象
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decode(String.self, forKey: .id)
                content = try? c.decode([Block].self, forKey: .content)
                source = try? c.decode(Source.self, forKey: .source)
                reason = try? c.decode(Source.self, forKey: .reason)
                callId = try? c.decode(String.self, forKey: .callId)
                name = try? c.decode(String.self, forKey: .name)
                arguments = try? c.decode(String.self, forKey: .arguments)
                error = try? c.decode(String.self, forKey: .error)
                title = try? c.decode(String.self, forKey: .title)
                delivery = try? c.decode(String.self, forKey: .delivery)
                message = try? c.decode(Message.self, forKey: .message)
                messageID = message == nil ? try? c.decode(String.self, forKey: .message) : nil
            }
        }

        struct Source: Decodable { var kind: String? }

        struct Message: Decodable {
            var id: String?
            var content: [Block]?
            var toolCallId: String?
            var isError: Bool?
        }

        struct Block: Decodable {
            var type: String
            var text: String?
            var attachment: Attachment?
        }

        struct Attachment: Decodable { var attachmentId: String? }
    }
}
#endif
