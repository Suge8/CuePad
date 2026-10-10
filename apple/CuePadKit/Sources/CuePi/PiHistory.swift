#if os(macOS)
import CueStore
import Foundation

/// 会话列表要的摘要：会话 id、工作目录、名字、首条用户消息、最后活动时间。原文留在会话文件里，这里不复制。
public struct PiSessionHistory: Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var name: String?
    /// 文件里第一条有文字的用户消息（文字块用空格连接，最多 `PiSessionName.firstMessageLimit` 字）。
    public var firstMessage: String?
    public var lastActivity: Date?

    /// 会话的显示名，规则见 `PiSessionName`（与活动会话、Pi 会话列表一致）。
    public var displayName: String {
        PiSessionName.display(name: name, firstMessage: firstMessage, folder: cwd.map { URL(filePath: $0).lastPathComponent } ?? "")
    }
}

/// 增量索引的可持久化状态。调用方存起来（Codable），下次传回来就只读新增字节。只存摘要与跨行的轮次状态，不存正文。
public struct PiHistoryCheckpoint: Sendable, Codable, Equatable {
    /// 已消费到的字节偏移（总在一个换行之后）
    public internal(set) var offset: UInt64 = 0
    var fingerprint: UInt64 = 0
    var fingerprintLength = 0
    var sessionID: String?
    var cwd: String?
    var name: String?
    var lastActivity: Date?
    var firstMessage: String?
    /// 已消费的行数（对话消息的 `seq`）。加对话之前的检查点没有它、解不开，从头重读一次补出对话
    var seq: Int64 = 0
    /// 这一轮还没做完：开始时间与已调的工具
    var round: Round?
    var recap = PiRecap()

    struct Round: Sendable, Codable, Equatable {
        var startedAt: Date?
        var tools = PiToolLog()
    }
}

public struct PiHistoryUpdate: Sendable {
    public var file: URL
    public var checkpoint: PiHistoryCheckpoint
    public var history: PiSessionHistory
    /// 这次新读到的对话（从头读时是全部）；`includesTranscript` 为 false 时（只读了摘要）为空
    public var messages: [PiChatMessage]
    /// 这次读的时候要不要对话（调用方——索引器按文件修改时间——的判定）：写不写对话以它为准
    public var includesTranscript: Bool
    /// 会话 id：会话文件头里的，没有就用文件名（与会话索引的 id 同一规则）
    public var sessionID: String { history.sessionID ?? file.deletingPathExtension().lastPathComponent }
    public var recap: PiRecap { checkpoint.recap }
    /// 这次读到的对话与摘要，交给 `CueStore.writePiTranscript`
    public var transcript: PiTranscript { PiTranscript(sessionID: sessionID, messages: messages, recap: recap) }
    /// 这次新消费的字节数（半行不算）
    public var bytesRead: Int
}

public enum PiHistoryEvent: Sendable {
    case updated(PiHistoryUpdate)
    /// 首次回填（按修改时间倒序）全部完成；之后只有文件变化触发的 `updated`。
    /// `sessionFiles` 是此刻全部会话文件：不在其中的旧索引（文件已删除等）可以丢掉
    case backfillFinished(sessionFiles: [URL])
}

/// Pi 会话文件（JSONL，v3 树结构）的解析。当前分支 = 从文件最后一个条目沿 `parentId` 回溯到根，
/// 与 Pi 加载会话时确定叶子的规则一致。
public enum PiHistory {

    private static let fingerprintPrefix = 256
    private static let blockSize = 8 * 1024 * 1024

    /// 从检查点继续索引 `file`（没有检查点或检查点已失效则从头）。文件不存在时抛错——
    /// 会话文件在第一条消息落盘前并不存在，调用方等文件出现再来。
    ///
    /// `transcript` 为 false 时不要对话（7 天外的会话）：从头读时只读摘要——逐行只找换行，只解码文件头、改名与第一条你的消息，
    /// 最近一轮的问答从文件尾往回解码到够用为止；得到的检查点与逐行全读一样，之后增量读接得上。
    public static func index(file: URL, from checkpoint: PiHistoryCheckpoint?, transcript wanted: Bool = true) throws -> PiHistoryUpdate {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        let resumed = try checkpoint.flatMap { try isResumable($0, handle: handle, size: size) ? $0 : nil }
        var state = resumed ?? PiHistoryCheckpoint()
        let start = state.offset
        var transcript = Transcript(fallbackID: file.deletingPathExtension().lastPathComponent)
        let consumed: UInt64
        if wanted || resumed != nil {
            consumed = try forEachLine(handle, from: start, size: size) { line, _ in ingest(line, into: &state, transcript: &transcript) }
            if !wanted { transcript.messages = [] }
        } else {
            var lines: [Skimmed] = []
            consumed = try forEachLine(handle, from: start, size: size) { line, offset in skim(line, at: offset, into: &state, lines: &lines) }
            try settle(&state, lines: lines, handle: handle)
        }
        state.offset = consumed
        try refreshFingerprint(&state, handle: handle)
        return PiHistoryUpdate(
            file: file, checkpoint: state, history: history(of: state), messages: transcript.messages, includesTranscript: wanted,
            bytesRead: Int(consumed - start))
    }

    /// 逐个完整行（不含换行）交给 `body`，带行首偏移；返回消费到的偏移（总在一个换行之后，末尾的半行不算）。
    private static func forEachLine(
        _ handle: FileHandle, from start: UInt64, size: UInt64, _ body: (UnsafeRawBufferPointer, UInt64) throws -> Void
    ) throws -> UInt64 {
        try handle.seek(toOffset: start)
        // 缓冲按剩余字节分配：启动回填时绝大多数文件没有新内容，每个都分配并清零 8 MB 是回填的主要开销
        var block = [UInt8](repeating: 0, count: Int(min(UInt64(blockSize), size - start)))
        guard !block.isEmpty else { return start }
        var carry: [UInt8] = []
        var consumed = start
        while true {
            let n = block.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            try block.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                var position = 0
                while position < n {
                    guard let hit = memchr(base + position, 0x0A, n - position) else {
                        carry.append(contentsOf: UnsafeRawBufferPointer(start: base + position, count: n - position))
                        break
                    }
                    let end = base.distance(to: UnsafeRawPointer(hit))
                    let piece = UnsafeRawBufferPointer(start: base + position, count: end - position)
                    if carry.isEmpty {
                        try body(piece, consumed)
                    } else {
                        carry.append(contentsOf: piece)
                        try carry.withUnsafeBytes { try body($0, consumed) }
                    }
                    consumed += UInt64((carry.isEmpty ? piece.count : carry.count) + 1)
                    carry.removeAll(keepingCapacity: true)
                    position = end + 1
                }
            }
        }
        return consumed
    }

    // MARK: 检查点有效性

    /// 文件被 Pi 改写（版本迁移）或替换后，旧偏移指向的可能是半行：检查文件没变短、开头没变、偏移落在换行之后。
    private static func isResumable(_ cp: PiHistoryCheckpoint, handle: FileHandle, size: UInt64) throws -> Bool {
        guard cp.offset <= size else { return false }
        if cp.offset == 0 { return true }
        try handle.seek(toOffset: cp.offset - 1)
        guard try handle.read(upToCount: 1) == Data([0x0A]) else { return false }
        return try fingerprint(handle, length: cp.fingerprintLength) == cp.fingerprint
    }

    private static func refreshFingerprint(_ cp: inout PiHistoryCheckpoint, handle: FileHandle) throws {
        cp.fingerprintLength = Int(min(UInt64(fingerprintPrefix), cp.offset))
        cp.fingerprint = try fingerprint(handle, length: cp.fingerprintLength)
    }

    /// FNV-1a 64
    private static func fingerprint(_ handle: FileHandle, length: Int) throws -> UInt64 {
        try handle.seek(toOffset: 0)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in try handle.read(upToCount: length) ?? Data() { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    // MARK: 解码

    private struct Line: Decodable {
        var type: String
        var id: String?
        var parentId: String?
        var timestamp: String?
        var cwd: String?
        var name: String?
        var message: Message?

        var time: Date? { timestamp.flatMap { try? Date($0, strategy: PiHistory.timestampStyle) } }
    }

    private struct Message: Decodable {
        var role: String
        var content: Content?
        var stopReason: String?
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
            /// 工具调用（type 为 toolCall）
            var id: String?
            var name: String?
            var arguments: PiToolArguments?
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
        }

        /// 文字块用空格连接（与 Pi 会话列表取首条消息一致）
        var text: String { joined(" ") }

        func joined(_ separator: String) -> String {
            switch self {
            case .text(let s): s
            case .blocks(let b): b.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: separator)
            }
        }

        var toolCalls: [Block] {
            guard case .blocks(let b) = self else { return [] }
            return b.filter { $0.type == "toolCall" }
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

    /// 这次新读到的对话消息；会话 id 取文件头的，没读到文件头就用文件名。
    private struct Transcript {
        let fallbackID: String
        var messages: [PiChatMessage] = []

        mutating func add(
            _ cp: PiHistoryCheckpoint, entryID: String, seq: Int64, role: PiChatRole, text: String, at: Date,
            tools: PiChatMessage.Tools? = nil, roundStartedAt: Date? = nil, deliveryID: String? = nil
        ) {
            messages.append(PiChatMessage(
                sessionID: cp.sessionID ?? fallbackID, entryID: entryID, seq: seq, role: role, text: text, at: at, tools: tools,
                roundStartedAt: roundStartedAt, deliveryID: deliveryID.flatMap(UUID.init(uuidString:))))
        }
    }

    private static func ingest(_ raw: UnsafeRawBufferPointer, into cp: inout PiHistoryCheckpoint, transcript: inout Transcript) {
        cp.seq += 1
        if let result = toolResult(raw) {
            cp.round?.tools.finish(id: result.id, failed: result.failed)
            return
        }
        guard let line = decode(raw) else { return } // 损坏行跳过
        let time = line.time
        // 最后活动：最后一行的时间（Pi 按时间追加）
        if let time { cp.lastActivity = time }
        switch line.type {
        case "session":
            cp.sessionID = line.id
            cp.cwd = line.cwd
        case "session_info":
            cp.name = line.name
        case "compaction":
            transcript.add(
                cp, entryID: line.id ?? "\(cp.seq)", seq: cp.seq, role: .system, text: "已压缩上下文", at: time ?? cp.lastActivity ?? .distantPast)
        case "message":
            guard let message = line.message else { return }
            if cp.firstMessage == nil, message.role == "user" {
                let text = message.content?.text ?? ""
                if !text.isEmpty { cp.firstMessage = String(text.prefix(PiSessionName.firstMessageLimit)) }
            }
            let entry = (id: line.id ?? "\(cp.seq)", seq: cp.seq, at: time ?? cp.lastActivity ?? .distantPast)
            switch message.role {
            case "user": userMessage(message, entry, into: &cp, transcript: &transcript)
            case "assistant": assistantMessage(message, entry, into: &cp, transcript: &transcript)
            case "toolResult":
                if let id = message.toolCallId { cp.round?.tools.finish(id: id, failed: message.isError == true) }
            default: break
            }
        default:
            break
        }
    }

    private typealias Entry = (id: String, seq: Int64, at: Date)

    /// 你说的一句：进对话、成为进行中的提问。机器消息（扩展投进来的信封）不进对话，只开始一轮。
    private static func userMessage(_ message: Message, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout Transcript) {
        if cp.round?.startedAt == nil { cp.round = .init(startedAt: entry.at, tools: cp.round?.tools ?? PiToolLog()) }
        let text = message.content?.joined("\n") ?? ""
        guard !isMachineMessage(text) else { return }
        transcript.add(cp, entryID: entry.id, seq: entry.seq, role: .user, text: text, at: entry.at, deliveryID: message.cuepadDelivery)
        cp.recap.pendingPrompt = clip(collapsed(text), PiRecap.promptLimit)
    }

    /// 助手消息：中途调工具的（`stopReason` 为 `toolUse`）只累计这一轮的工具活动；结束一轮的成一条 Pi 消息，问与答一起更新摘要。
    private static func assistantMessage(_ message: Message, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout Transcript) {
        var round = cp.round ?? .init(startedAt: nil)
        for call in message.content?.toolCalls ?? [] {
            round.tools.start(id: call.id ?? "", name: call.name ?? "", arguments: call.arguments ?? PiToolArguments(), cwd: cp.cwd)
        }
        guard message.stopReason != "toolUse" else {
            cp.round = round
            return
        }
        let text = (message.content?.joined("\n") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            transcript.add(
                cp, entryID: entry.id, seq: entry.seq, role: .pi, text: text, at: entry.at, tools: round.tools.summary(),
                roundStartedAt: round.startedAt)
        }
        cp.recap = PiRecap(
            lastPrompt: cp.recap.pendingPrompt ?? cp.recap.lastPrompt, lastReply: clip(text, PiRecap.replyLimit), pendingPrompt: nil)
        cp.round = nil
    }

    /// 扩展投进会话的机器消息：整条文字只由一个或多个 `<名字>\n…\n</名字>` 块组成（如 FireCode 的 `<firecode_master_event>`、
    /// `<firecode_review>`）。块正文止于第一个同名闭合标签：块与块之间夹着真人文字时整条不匹配。
    private static let machineMessage = try! NSRegularExpression(pattern: #"^(?:<([A-Za-z][\w.-]*)>\n(?:(?!\n</\1>)[\s\S])*\n</\1>\s*)+$"#)

    static func isMachineMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return machineMessage.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) } })
            .joined(separator: " ")
    }

    /// 去掉首尾空白后截到 `limit` 个字符（超出的以省略号结尾）；空文字为 nil。
    private static func clip(_ text: String, _ limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit - 1)) + "…"
    }

    private static let decoder = JSONDecoder()

    private static func decode(_ raw: UnsafeRawBufferPointer) -> Line? {
        guard let base = raw.baseAddress, !raw.isEmpty else { return nil }
        return try? decoder.decode(Line.self, from: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: raw.count, deallocator: .none))
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

    // MARK: 只读摘要

    /// 只读摘要时记下的一行：行首偏移、长度；元信息行（文件头、改名）已当场读过。
    private struct Skimmed {
        var offset: UInt64
        var length: Int
        var kind: Kind
        enum Kind { case meta, toolResult, other }
    }

    private static let sessionInfoMarker = Data(#""type":"session_info""#.utf8)
    private static let userMarker = Data(#""role":"user""#.utf8)
    private static let roleMarker = Data(#""role":"#.utf8)

    /// 只找换行时的一行：文件头与改名当场解码；第一条你的消息找到之前解码像是你说的行（取标题）；其余只记位置。
    private static func skim(_ raw: UnsafeRawBufferPointer, at offset: UInt64, into cp: inout PiHistoryCheckpoint, lines: inout [Skimmed]) {
        cp.seq += 1
        guard !raw.isEmpty else { return }
        let head = head(raw)
        if offset == 0 || contains(head, sessionInfoMarker) {
            if let line = decode(raw), line.type == "session" || line.type == "session_info" {
                switch line.type {
                case "session": (cp.sessionID, cp.cwd) = (line.id, line.cwd)
                default: cp.name = line.name
                }
                lines.append(Skimmed(offset: offset, length: raw.count, kind: .meta))
                return
            }
        }
        if isToolResult(raw) {
            lines.append(Skimmed(offset: offset, length: raw.count, kind: .toolResult))
            return
        }
        if cp.firstMessage == nil, contains(head, userMarker) || !contains(head, roleMarker),
           let line = decode(raw), line.type == "message", line.message?.role == "user" {
            let text = line.message?.content?.text ?? ""
            if !text.isEmpty { cp.firstMessage = String(text.prefix(PiSessionName.firstMessageLimit)) }
        }
        lines.append(Skimmed(offset: offset, length: raw.count, kind: .other))
    }

    /// 从文件尾往回解码：最后活动（最后一行的时间）、最近一轮做完的问答；还没做完的那一轮（最后一条回答之后的行）
    /// 按逐行读的规则重放，得到它的开始时间、已调的工具与进行中的提问——与逐行全读得到的一样。
    private static func settle(_ cp: inout PiHistoryCheckpoint, lines: [Skimmed], handle: FileHandle) throws {
        func read(_ line: Skimmed) throws -> Data? {
            try handle.seek(toOffset: line.offset)
            return try handle.read(upToCount: line.length)
        }
        func decoded(_ line: Skimmed) throws -> Line? {
            try read(line)?.withUnsafeBytes { decode($0) }
        }
        for line in lines.reversed() where line.kind != .toolResult {
            if let time = try decoded(line)?.time {
                cp.lastActivity = time
                break
            }
        }
        var final: String?
        var lastPrompt: String?
        var unfinished = 0 // 最后一条回答之后的第一行
        for (index, skimmed) in lines.enumerated().reversed() where skimmed.kind == .other {
            guard let line = try decoded(skimmed), line.type == "message", let message = line.message else { continue }
            let text = message.content?.joined("\n") ?? ""
            if final == nil {
                if message.role == "assistant", message.stopReason != "toolUse" {
                    final = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    unfinished = index + 1
                }
            } else if message.role == "user", !isMachineMessage(text) {
                lastPrompt = clip(collapsed(text), PiRecap.promptLimit)
                break
            }
        }
        var rest = cp
        rest.round = nil
        rest.recap.pendingPrompt = nil
        var ignored = Transcript(fallbackID: "")
        for line in lines[unfinished...] where line.kind != .meta {
            try read(line)?.withUnsafeBytes { ingest($0, into: &rest, transcript: &ignored) }
        }
        cp.round = rest.round
        cp.recap = PiRecap(
            lastPrompt: final == nil ? nil : lastPrompt, lastReply: final.flatMap { clip($0, PiRecap.replyLimit) },
            pendingPrompt: rest.recap.pendingPrompt)
    }

    static func history(of cp: PiHistoryCheckpoint) -> PiSessionHistory {
        PiSessionHistory(
            sessionID: cp.sessionID, cwd: cp.cwd, name: cp.name, firstMessage: cp.firstMessage, lastActivity: cp.lastActivity)
    }
}
#endif
