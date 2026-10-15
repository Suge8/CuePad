#if os(macOS)
import CueStore
import CueText
import Foundation

/// 会话列表要的摘要：会话 id、工作目录、名字、首条用户消息、最后活动时间。原文留在会话文件里，这里不复制。
public struct PiSessionHistory: Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var name: String?
    /// 第一条有文字的你的话（`PiSessionName.firstMessage`）。
    public var firstMessage: String?
    public var lastActivity: Date?

    /// 会话的显示名，规则见 `PiSessionName`（与活动会话、Pi 会话列表一致）。
    public var displayName: String {
        PiSessionName.display(name: name, firstMessage: firstMessage, folder: cwd.map { URL(filePath: $0).lastPathComponent } ?? "")
    }
}

/// 增量索引的可持久化状态。调用方存起来（Codable），下次传回来就只读新增字节。只存摘要与跨行的轮次状态，不存正文。
/// 解不开（格式随 CuePi 升级变了）的检查点当作没有，从头重读。
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
    /// 已消费的行数（对话消息的 `seq`）
    var seq: Int64 = 0
    /// 这一轮还没做完：开始时间与已调的工具
    var round: Round?
    /// 最近你说的那句之后、助手最后说的一段（还没归给那句：等下一句你的话或这一轮结束）
    var reply: Reply?
    var recap = PiRecap()
    /// 解码时认出这个文件不是会话列表里的会话（如 Codex 子代理自己的会话文件，与主会话同层）：索引器不发出它
    var excluded = false

    struct Round: Sendable, Codable, Equatable {
        var startedAt: Date?
        var tools = PiToolLog()
        /// 这一轮里你拒绝过它要用的工具（这一轮因此停下时写"已拒绝"）
        var declined = false
    }

    struct Reply: Sendable, Codable, Equatable {
        var text: String
        var id: String
        var seq: Int64
        var at: Date
    }
}

/// 索引一个会话文件从哪接着读：上次的检查点（没有或解不开为 nil），与本机是否已存着它的对话
/// （范围内的会话要有全部消息：没有就从头读一遍补齐；范围外的存着对话的也整份重读，已存的消息跟着读文件的规则更新）。
public struct PiHistoryStart: Sendable {
    public var checkpoint: PiHistoryCheckpoint?
    public var hasTranscript: Bool

    public init(checkpoint: PiHistoryCheckpoint?, hasTranscript: Bool) {
        self.checkpoint = checkpoint
        self.hasTranscript = hasTranscript
    }
}

public struct PiHistoryUpdate: Sendable {
    public var file: URL
    public var agent: AgentKind
    public var checkpoint: PiHistoryCheckpoint
    public var history: PiSessionHistory
    /// 这次新读到的对话（从头读时是全部）；`includesTranscript` 为 false 时（只读了摘要）为空
    public var messages: [PiChatMessage]
    /// 这次读的时候要不要对话（调用方——索引器——的判定）：写不写对话以它为准
    public var includesTranscript: Bool
    /// 会话文件的修改时间（列目录或读文件时取的）
    public var modified: Date?
    /// 算不算一个会话：Pi、Codex 的会话文件先建出来、文件头随后才写，读到文件头之前它还不是会话（文件名不是会话 id），
    /// 索引器不发出它——按文件名记下会多出一条没名字的孤儿会话。文件名就是会话 id 的（Claude Code）总算（`SessionFileFormat`）。
    public var isSession: Bool
    /// 会话 id：会话文件头里的；还没读到文件头时是文件名（只有文件名就是会话 id 的才会这样发出）。
    public var sessionID: String { history.sessionID ?? file.deletingPathExtension().lastPathComponent }
    public var recap: PiRecap { checkpoint.projectedRecap }
    /// 这次读到的对话与摘要，交给 `CueStore.writePiTranscript`
    public var transcript: PiTranscript { PiTranscript(sessionID: sessionID, messages: messages, recap: recap) }
    /// 这次新消费的字节数（半行不算）
    public var bytesRead: Int
}

public enum PiHistoryEvent: Sendable {
    case updated(PiHistoryUpdate)
    /// 首次回填（按修改时间倒序）全部完成；之后只有文件变化触发的 `updated`。
    /// `sessionFiles` 是此刻全部会话文件（文件头还没写好的不算）：不在其中的旧索引（文件已删除、按文件名记下的等）可以丢掉
    case backfillFinished(sessionFiles: [URL])
}

/// 一家 Agent 的会话文件怎么认、怎么读：唯一的一处（会话目录本身在 `AgentPaths.sessionsDirectory`）。OpenCode 的会话在它的数据库里，没有。
struct SessionFileFormat: Sendable {
    /// 一行会话文件（不含换行）的解码：经检查点上的那几个变化（`said`、`answered`……）更新摘要与轮次，你的话与每轮的回答加进对话。
    /// 损坏或不认识的行跳过。
    typealias Ingest = @Sendable (UnsafeRawBufferPointer, inout PiHistoryCheckpoint, inout PiHistory.Transcript) throws -> Void

    let ingest: Ingest
    /// 会话文件在会话目录下第几层，与各家自己的会话列表一致：Pi 与 Claude Code 是 `<项目目录>/*.jsonl`（更深的，如子代理的
    /// `<项目目录>/…/subagents/*.jsonl`，不是会话列表里的会话）；Codex 是 `YYYY/MM/DD/rollout-*.jsonl`。
    let depth: Int
    /// Agent 写会话文件时一直开着它（Codex 的常驻服务整段会话都开着）：FSEvents 只在关闭时报，要另盯追加
    let keepsFilesOpen: Bool
    /// 文件名就是会话 id（Claude Code）：文件头还没读到也算会话
    let nameIsSessionID: Bool

    static func of(_ agent: AgentKind) -> SessionFileFormat? {
        switch agent {
        case .pi: SessionFileFormat(ingest: PiHistory.ingest, depth: 2, keepsFilesOpen: false, nameIsSessionID: false)
        case .claudeCode: SessionFileFormat(ingest: ClaudeHistory.ingest, depth: 2, keepsFilesOpen: false, nameIsSessionID: true)
        case .codex: SessionFileFormat(ingest: CodexHistory.ingest, depth: 4, keepsFilesOpen: true, nameIsSessionID: false)
        case .opencode: nil
        }
    }
}

/// Agent 会话文件（JSONL）的增量解析：读取、检查点、轮次与摘要的规则各家共用（检查点上的 `said`、`answered`、`interrupted`、
/// `compacted` 与工具活动），逐行的解码按 Agent 分（`SessionFileFormat`；Pi 的在这里，Claude Code、Codex 的在 `ClaudeHistory`、
/// `CodexHistory`；OpenCode 的会话在它的数据库里，`OpenCodeHistory` 经它的接口逐条读进同样的检查点）。
/// Pi 的会话文件是 v3 树结构：当前分支 = 从文件最后一个条目沿 `parentId` 回溯到根，与 Pi 加载会话时确定叶子的规则一致。
public enum PiHistory {
    private static let fingerprintPrefix = 256
    private static let blockSize = 8 * 1024 * 1024

    /// 从检查点继续索引 `file`（没有检查点或检查点已失效则从头）。文件不存在时抛错——
    /// 会话文件在第一条消息落盘前并不存在，调用方等文件出现再来。
    ///
    /// 你的消息里的图片当场存进 `files`（按内容哈希，已有的不重写），对话里只留 `![](cuepad://img/<哈希>)`：会话文件是图片唯一的来源，
    /// 终端里贴的图片附件目录里原本没有。不是图片的块跳过；存不下（磁盘错误）时抛错，不留一条缺图的消息。
    ///
    /// `transcript` 为 false 时不要对话（7 天外的会话）：照样逐行读出检查点，丢掉对话、不存图片（工具结果行不做 JSON 解码，
    /// 600 MB 的 Pi 会话文件实测不到 1 秒，不另做只读摘要的快速路径——那会是第二份轮次规则）。
    public static func index(
        file: URL, agent: AgentKind, from checkpoint: PiHistoryCheckpoint?, transcript wanted: Bool = true, modified: Date? = nil,
        files: AttachmentFiles
    ) throws -> PiHistoryUpdate {
        guard let format = SessionFileFormat.of(agent) else { preconditionFailure("\(agent.name) 的会话不在文件里") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        let resumed = try checkpoint.flatMap { try isResumable($0, handle: handle, size: size) ? $0 : nil }
        var state = resumed ?? PiHistoryCheckpoint()
        let start = state.offset
        var transcript = Transcript(fallbackID: file.deletingPathExtension().lastPathComponent, files: wanted ? files : nil)
        let consumed = try forEachLine(handle, from: start, size: size) { line in try format.ingest(line, &state, &transcript) }
        if !wanted { transcript.messages = [] }
        state.offset = consumed
        try refreshFingerprint(&state, handle: handle)
        let history = PiSessionHistory(
            sessionID: state.sessionID, cwd: state.cwd, name: state.name, firstMessage: state.firstMessage, lastActivity: state.lastActivity)
        return PiHistoryUpdate(
            file: file, agent: agent, checkpoint: state, history: history, messages: transcript.messages, includesTranscript: wanted,
            modified: modified, isSession: history.sessionID != nil || format.nameIsSessionID, bytesRead: Int(consumed - start))
    }

    /// 逐个完整行（不含换行）交给 `body`；返回消费到的偏移（总在一个换行之后，末尾的半行不算）。
    private static func forEachLine(
        _ handle: FileHandle, from start: UInt64, size: UInt64, _ body: (UnsafeRawBufferPointer) throws -> Void
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
                        try body(piece)
                    } else {
                        carry.append(contentsOf: piece)
                        try carry.withUnsafeBytes { try body($0) }
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

    // MARK: 对话与轮次（各家共用）

    /// 一条消息在会话里的位置：条目 id（没有时用行号）、行号（`seq`）、时间。
    struct Entry {
        var id: String
        var seq: Int64
        var at: Date
    }

    /// 这次新读到的对话消息；会话 id 取文件头的，没读到文件头就用文件名。`files` 是你的消息里的图片要存进的附件目录；
    /// nil 是只为推出检查点状态而重放的行（消息丢弃，不存图片）。
    struct Transcript {
        let fallbackID: String
        let files: AttachmentFiles?
        var messages: [PiChatMessage] = []

        mutating func add(
            _ cp: PiHistoryCheckpoint, _ entry: Entry, role: PiChatRole, text: String, tools: PiChatMessage.Tools? = nil,
            roundStartedAt: Date? = nil, deliveryID: String? = nil
        ) {
            messages.append(PiChatMessage(
                sessionID: cp.sessionID ?? fallbackID, entryID: entry.id, seq: entry.seq, role: role, text: text, at: entry.at, tools: tools,
                roundStartedAt: roundStartedAt, deliveryID: deliveryID.flatMap(UUID.init(uuidString:))))
        }

        /// 拼你说的一句话：按块的原顺序加文字与图片。
        func said() -> Said { Said(files: files) }
    }

    /// 你说的一句：文字块去掉 Pi 附给模型的图片说明行（`PiSessionName.withoutImageNotes`），图片存进附件目录。
    /// `text` 是文字块用换行连接（标题、摘要、机器消息判断都用它），`stored` 是文字与图片按块的原顺序拼成的正文格式（`CueFormat`，
    /// 与投送请求的 content 同一种；不存图片时等同 `text`）。
    struct Said {
        fileprivate let files: AttachmentFiles?
        private var texts: [String] = []
        private var pieces: [String] = []

        fileprivate init(files: AttachmentFiles?) { self.files = files }

        mutating func text(_ block: String?) {
            let text = PiSessionName.withoutImageNotes(block ?? "")
            guard !text.isEmpty else { return }
            texts.append(text)
            pieces.append(text)
        }

        /// 图片原字节；不是图片的跳过。
        mutating func image(_ data: Data?) throws {
            guard let files, let data else { return }
            do { pieces.append(CueFormat.imageMarkup(id: try files.store(data))) } catch CueStoreError.notAnImage {}
        }

        var text: String { texts.joined(separator: "\n") }
        var stored: String { files == nil ? text : pieces.joined(separator: "\n") }
    }

    /// 去掉首尾空白后截到 `limit` 个字符（超出的以省略号结尾）；空文字为 nil。
    static func clip(_ text: String, _ limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit - 1)) + "…"
    }

    /// 单行：空白与控制字符折成一个空格。
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) } })
            .joined(separator: " ")
    }

    // MARK: Pi 的会话文件

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
}

// MARK: - 轮次与摘要的规则（各家共用）

/// 对话里每句你的话，回答是它之后、下一句你的话之前助手说的最后一段：各家的解码把助手说的每一段交给 `spoke`，
/// 下一句你的话（`said`，含一轮在跑时插进来的）或这一轮结束（`answered`）时，最后那段归给前一句。
/// 没有回答就结束的一轮按现有规则：被停下留"已停止"（`interrupted`）。
extension PiHistoryCheckpoint {
    /// 写到会话记录上的摘要：问答，加上进行中这一轮到目前为止的经过（`PiRecap.pendingTools`，由轮次推出、不另存）。
    var projectedRecap: PiRecap {
        var projected = recap
        projected.pendingTools = round?.tools.settled
        return projected
    }

    /// 你说的一句：第一条有文字的成为标题（`PiSessionName.firstMessage`），开始一轮，进对话、成为进行中的提问（单行，≤`PiRecap.promptLimit`）。
    /// 整条是信封的（`PiEnvelope`）是扩展借你的名义投进来的机器消息，按 `machine` 处理。
    /// 一轮在跑时插进来的你的话：前一句已有的回答先归给前一句，之后的话与工具活动算这一句的。
    mutating func said(_ said: PiHistory.Said, _ entry: PiHistory.Entry, deliveryID: String?, into transcript: inout PiHistory.Transcript) {
        if firstMessage == nil { firstMessage = PiSessionName.firstMessage(said.text) }
        guard PiEnvelope.parse(said.text) == nil else { return machine(said.text, entry, into: &transcript) }
        if reply != nil {
            settleReply(into: &transcript)
            round = Round(startedAt: entry.at)
        }
        if round?.startedAt == nil { round = Round(startedAt: entry.at, tools: round?.tools ?? PiToolLog()) }
        transcript.add(self, entry, role: .user, text: said.stored, deliveryID: deliveryID)
        recap.pendingPrompt = PiHistory.clip(PiHistory.collapsed(said.text), PiRecap.promptLimit)
    }

    /// 扩展投进会话的机器消息（FireCode 交回子代理结果、审查结论……）：原样进对话（`machine`），开始一轮（在跑时接着这一轮），
    /// 但不是提问，也不把前面说的那段归成回答。
    mutating func machine(_ text: String, _ entry: PiHistory.Entry, into transcript: inout PiHistory.Transcript) {
        if round?.startedAt == nil { round = Round(startedAt: entry.at, tools: round?.tools ?? PiToolLog()) }
        transcript.add(self, entry, role: .machine, text: text)
    }

    /// 这一轮开始（Agent 自己标出开始的，如 Codex 的 `task_started`）：重新计时、清掉工具活动。
    mutating func roundStarted(at date: Date) {
        round = Round(startedAt: date)
    }

    mutating func toolStarted(id: String, name: String, arguments: PiToolArguments) {
        var current = round ?? Round(startedAt: nil)
        current.tools.start(id: id, name: name, arguments: arguments, cwd: cwd)
        round = current
    }

    mutating func toolFinished(id: String, failed: Bool) {
        round?.tools.finish(id: id, failed: failed)
    }

    /// 你拒绝了它要用的工具（权限确认答了"否"）。
    mutating func toolDeclined(id: String) {
        round?.tools.finish(id: id, failed: true)
        round?.declined = true
    }

    /// 助手说了一段（中途调工具前说的、插话后答的、这一轮最后的回答都是）：空白的不算。每段都按先后记进这一轮的经过，
    /// 最后那段在这一轮做完时成为回答、从经过里拿掉（`PiToolLog.summary`）。
    mutating func spoke(_ text: String, _ entry: PiHistory.Entry) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var current = round ?? Round(startedAt: nil)
        current.tools.say(text)
        round = current
        reply = Reply(text: text, id: entry.id, seq: entry.seq, at: entry.at)
    }

    /// 这一轮做完，`text` 是结束它的那段（可以为空——如只调了工具、出错）：最后说的那段成一条消息，带这一轮的工具活动，
    /// 问与答一起更新——提问是这一轮里你说的话，机器消息触发的轮沿用上一次的提问。什么都没说、也没有提问的（只压缩了上下文）只结束这一轮。
    mutating func answered(_ text: String, _ entry: PiHistory.Entry, into transcript: inout PiHistory.Transcript) {
        spoke(text, entry)
        if reply != nil {
            settleReply(into: &transcript)
        } else if let prompt = recap.pendingPrompt {
            recap = PiRecap(lastPrompt: prompt, lastReply: "", pendingPrompt: nil)
        }
        round = nil
    }

    /// 进行中的一轮被停下了（终端里 Esc、CuePad 里"停止这一轮"，或你拒绝了它要用的工具）：已经说出的照样是回答——
    /// 被停下的那条里说了一半的（`said`）也算，它就是最后一段；什么都没说的问答不变、提问不再算进行中。
    /// 对话里在回答下面留一行系统行，因拒绝而停的写"已拒绝"，其余"已停止"。系统行用这一条的 id；说了一半的那段与它同在一条里，
    /// id 后加 `#said`，同序号时说的话排在系统行前（`CueStore.piMessages`）。
    mutating func interrupted(_ entry: PiHistory.Entry, said: String = "", into transcript: inout PiHistory.Transcript) {
        guard let current = round else { return }
        spoke(said, PiHistory.Entry(id: entry.id + "#said", seq: entry.seq, at: entry.at))
        if reply != nil { settleReply(into: &transcript) }
        transcript.add(self, entry, role: .system, text: (current.declined ? PiNotice.declined : .stopped).rawValue)
        round = nil
        recap.pendingPrompt = nil
    }

    /// 压缩上下文：一行系统行，不动问答。
    mutating func compacted(_ entry: PiHistory.Entry, into transcript: inout PiHistory.Transcript) {
        transcript.add(self, entry, role: .system, text: PiNotice.compacted.rawValue)
    }

    /// 最后说的那段归给前一句：成一条消息（带到此为止的工具活动），问与答一起更新。
    private mutating func settleReply(into transcript: inout PiHistory.Transcript) {
        guard let reply else { return }
        let current = round ?? Round(startedAt: nil)
        transcript.add(
            self, PiHistory.Entry(id: reply.id, seq: reply.seq, at: reply.at), role: .pi, text: reply.text, tools: current.tools.summary(),
            roundStartedAt: current.startedAt)
        recap = PiRecap(lastPrompt: recap.pendingPrompt ?? recap.lastPrompt, lastReply: PiHistory.clip(reply.text, PiRecap.replyLimit), pendingPrompt: nil)
        self.reply = nil
    }
}
#endif
