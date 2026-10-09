#if os(macOS)
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

/// 对话里的一条：你说的一句，或 Pi 一轮最后的回答（一轮一条；中途调工具时说的话、思考与工具输出不算），
/// 或会话文件里的一条压缩记录（系统行：与终端对话里的压缩摘要同一件事），
/// 或 `cuepad_show` 工具成功的那一行（预览：Agent 发到手机上看的文件，正文是 CuePad 给的预览 id）。
public struct PiTranscriptEntry: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case user, pi, system, preview }

    /// 会话文件里那一条的 id
    public var entryID: String
    /// 那一条在文件里的行序号（文件只追加，重读不变）
    public var seq: Int64
    public var role: Role
    /// 你的消息是全文（文字块换行连接）；Pi 的是这一轮最后那条助手消息的文字块（换行连接）
    public var text: String
    public var at: Date
    /// Pi 消息：这一轮调了几个工具
    public var toolCount: Int
    /// Pi 消息：这一轮从哪一刻开始（你说话或机器消息到达）
    public var roundStartedAt: Date?
    /// 你的消息：CuePad 送进去时扩展写上的投送请求 id（`cuepadDelivery`）
    public var deliveryID: String?
}

/// 会话摘要：对话的投影。`lastPrompt` 与 `lastReply` 是最近一轮做完的问答，在这一轮结束时一起更新；
/// `pendingPrompt` 是你说了、这一轮还没做完的那句。机器消息触发的轮没有新的提问，回答照常更新、提问沿用。
public struct PiTranscriptRecap: Sendable, Codable, Equatable {
    /// 单行（空白与控制字符折成一个空格），至多 500 字符
    public var lastPrompt: String?
    /// 保留换行，至多 1200 字符
    public var lastReply: String?
    public var pendingPrompt: String?

    static let promptLimit = 500
    static let replyLimit = 1_200
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
    /// 这一轮还没做完：开始时间与已调的工具数
    var round: Round?
    var recap = PiTranscriptRecap()

    struct Round: Sendable, Codable, Equatable {
        var startedAt: Date?
        var tools = 0
    }
}

public struct PiHistoryUpdate: Sendable {
    public var file: URL
    public var checkpoint: PiHistoryCheckpoint
    public var history: PiSessionHistory
    /// 这次新读到的对话（从头读时是全部）；`includesTranscript` 为 false 时（只读了摘要）为空
    public var transcript: [PiTranscriptEntry]
    /// 这次读的时候要不要对话（调用方——索引器按文件修改时间——的判定）：写不写对话以它为准
    public var includesTranscript: Bool
    public var recap: PiTranscriptRecap { checkpoint.recap }
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
        var transcript: [PiTranscriptEntry] = []
        let consumed: UInt64
        if wanted || resumed != nil {
            consumed = try forEachLine(handle, from: start, size: size) { line, _ in ingest(line, into: &state, transcript: &transcript) }
            if !wanted { transcript = [] }
        } else {
            var lines: [Skimmed] = []
            consumed = try forEachLine(handle, from: start, size: size) { line, offset in skim(line, at: offset, into: &state, lines: &lines) }
            try settle(&state, lines: lines, handle: handle)
        }
        state.offset = consumed
        try refreshFingerprint(&state, handle: handle)
        return PiHistoryUpdate(
            file: file, checkpoint: state, history: history(of: state), transcript: transcript, includesTranscript: wanted,
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
        var tokensBefore: Int?
        var message: Message?

        var time: Date? { timestamp.flatMap { try? Date($0, strategy: PiHistory.timestampStyle) } }
    }

    private struct Message: Decodable {
        var role: String
        var content: Content?
        var stopReason: String?
        var cuepadDelivery: String?
        var toolName: String?
        var details: Details?

        struct Details: Decodable { var preview: String? }
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        struct Block: Decodable { var type: String; var text: String? }

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

        var toolCalls: Int {
            guard case .blocks(let b) = self else { return 0 }
            return b.count { $0.type == "toolCall" }
        }
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// toolResult 行占会话体积的绝大部分（工具输出、图片），又不含摘要要的东西：认出来就跳过，不做 JSON 解码。
    /// Pi 写出的键序固定为 type, id, parentId, timestamp, message，角色在行首附近。
    private static let toolResultMarker = Data(#""role":"toolResult""#.utf8)
    /// 例外：发到手机预览的工具（`cuepad_show`）的结果要解码——它很小，工具名就在行首附近。
    private static let showTool = "cuepad_show"
    private static let showToolMarker = Data(#""toolName":"\#(showTool)""#.utf8)
    private static let headLength = 512

    private static func ingest(_ raw: UnsafeRawBufferPointer, into cp: inout PiHistoryCheckpoint, transcript: inout [PiTranscriptEntry]) {
        cp.seq += 1
        if isToolResult(raw), !contains(head(raw), showToolMarker) { return }
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
            transcript.append(PiTranscriptEntry(
                entryID: line.id ?? "\(cp.seq)", seq: cp.seq, role: .system, text: compactionText(tokensBefore: line.tokensBefore),
                at: time ?? cp.lastActivity ?? .distantPast, toolCount: 0, roundStartedAt: nil, deliveryID: nil))
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
                // 成功的 cuepad_show 调用（结果里带着 CuePad 给的预览 id）：预览在对话里的位置就是这一行的位置
                guard message.toolName == showTool, let preview = message.details?.preview else { return }
                transcript.append(PiTranscriptEntry(
                    entryID: entry.id, seq: entry.seq, role: .preview, text: preview, at: entry.at, toolCount: 0, roundStartedAt: nil, deliveryID: nil))
            default: break
            }
        default:
            break
        }
    }

    /// 压缩的系统行："已压缩上下文 · 压缩前约 63k tokens"（不到 1000 写原数）。
    private static func compactionText(tokensBefore: Int?) -> String {
        guard let tokensBefore else { return "已压缩上下文" }
        return "已压缩上下文 · 压缩前约 " + (tokensBefore >= 1_000 ? "\(tokensBefore / 1_000)k" : "\(tokensBefore)") + " tokens"
    }

    private typealias Entry = (id: String, seq: Int64, at: Date)

    /// 你说的一句：进对话、成为进行中的提问。机器消息（扩展投进来的信封）不进对话，只开始一轮。
    private static func userMessage(_ message: Message, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout [PiTranscriptEntry]) {
        if cp.round?.startedAt == nil { cp.round = .init(startedAt: entry.at, tools: cp.round?.tools ?? 0) }
        let text = message.content?.joined("\n") ?? ""
        guard !isMachineMessage(text) else { return }
        transcript.append(PiTranscriptEntry(
            entryID: entry.id, seq: entry.seq, role: .user, text: text, at: entry.at, toolCount: 0, roundStartedAt: nil,
            deliveryID: message.cuepadDelivery))
        cp.recap.pendingPrompt = clip(collapsed(text), PiTranscriptRecap.promptLimit)
    }

    /// 助手消息：中途调工具的（`stopReason` 为 `toolUse`）只记工具数；结束一轮的成一条 Pi 消息，问与答一起更新摘要。
    private static func assistantMessage(_ message: Message, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout [PiTranscriptEntry]) {
        var round = cp.round ?? .init(startedAt: nil)
        round.tools += message.content?.toolCalls ?? 0
        guard message.stopReason != "toolUse" else {
            cp.round = round
            return
        }
        let text = (message.content?.joined("\n") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            transcript.append(PiTranscriptEntry(
                entryID: entry.id, seq: entry.seq, role: .pi, text: text, at: entry.at, toolCount: round.tools,
                roundStartedAt: round.startedAt, deliveryID: nil))
        }
        cp.recap = PiTranscriptRecap(
            lastPrompt: cp.recap.pendingPrompt ?? cp.recap.lastPrompt, lastReply: clip(text, PiTranscriptRecap.replyLimit), pendingPrompt: nil)
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
        raw.count > headLength && contains(head(raw), toolResultMarker)
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

    /// 从文件尾往回解码：最后活动（最后一行的时间）、最近一轮做完的问答、还没做完的那一轮——与逐行全读得到的一样。
    private static func settle(_ cp: inout PiHistoryCheckpoint, lines: [Skimmed], handle: FileHandle) throws {
        func read(_ line: Skimmed) throws -> Line? {
            try handle.seek(toOffset: line.offset)
            guard let data = try handle.read(upToCount: line.length) else { return nil }
            return data.withUnsafeBytes { decode($0) }
        }
        for line in lines.reversed() where line.kind != .toolResult {
            if let time = try read(line)?.time {
                cp.lastActivity = time
                break
            }
        }
        var final: String?
        var lastPrompt: String?
        var pending: String?
        var round: PiHistoryCheckpoint.Round?
        for skimmed in lines.reversed() where skimmed.kind == .other {
            guard let line = try read(skimmed), line.type == "message", let message = line.message else { continue }
            let text = message.content?.joined("\n") ?? ""
            if final == nil {
                switch message.role {
                case "assistant" where message.stopReason != "toolUse":
                    final = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case "assistant":
                    round = .init(startedAt: round?.startedAt, tools: (round?.tools ?? 0) + (message.content?.toolCalls ?? 0))
                case "user":
                    round = .init(startedAt: line.time ?? round?.startedAt, tools: round?.tools ?? 0)
                    if pending == nil, !isMachineMessage(text) { pending = clip(collapsed(text), PiTranscriptRecap.promptLimit) }
                default:
                    break
                }
            } else if message.role == "user", !isMachineMessage(text) {
                lastPrompt = clip(collapsed(text), PiTranscriptRecap.promptLimit)
                break
            }
        }
        cp.round = round
        cp.recap = PiTranscriptRecap(
            lastPrompt: final == nil ? nil : lastPrompt, lastReply: final.flatMap { clip($0, PiTranscriptRecap.replyLimit) },
            pendingPrompt: pending)
    }

    static func history(of cp: PiHistoryCheckpoint) -> PiSessionHistory {
        PiSessionHistory(
            sessionID: cp.sessionID, cwd: cp.cwd, name: cp.name, firstMessage: cp.firstMessage, lastActivity: cp.lastActivity)
    }
}
#endif
