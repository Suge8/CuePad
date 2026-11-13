#if os(macOS)
import CueStore
import CueText
import Foundation
import ImageIO

/// 原文留在会话文件里，这里不复制。
public struct SessionHistory: Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var name: String?
    public var firstMessage: String?
    public var lastActivity: Date?
    public var model: ModelKey?
    public var thinking: String?

    public var displayName: String {
        SessionName.display(name: name, firstMessage: firstMessage, folder: cwd.map { URL(filePath: $0).lastPathComponent } ?? "")
    }
}

/// （范围内的会话要有全部消息：没有就从头读一遍补齐；范围外的存着对话的也整份重读，已存的消息跟着读文件的规则更新）。
public struct HistoryStart: Sendable {
    public var checkpoint: HistoryCheckpoint?
    public var hasTranscript: Bool

    public init(checkpoint: HistoryCheckpoint?, hasTranscript: Bool) {
        self.checkpoint = checkpoint
        self.hasTranscript = hasTranscript
    }
}

public struct HistoryUpdate: Sendable {
    public var file: URL
    public var agent: AgentKind
    public var checkpoint: HistoryCheckpoint
    public var history: SessionHistory
    public var messages: [ChatMessage]
    /// 这次读的时候要不要对话（调用方——索引器——的判定）：写不写对话以它为准
    public var includesTranscript: Bool
    /// 这次读完会话名与接着读的那个检查点里的不一样（从头读的有名字就算）：Agent 这期间起了或改了名（`Bridge.read`）
    public var renamed: Bool
    /// 会话 id：会话文件头里的；还没读到文件头时是路径里的（只有文件名就是会话 id 的才会这样发出）。
    public var sessionID: String { history.sessionID ?? agent.facts.sessionFiles?.sessionID(of: file) ?? file.deletingPathExtension().lastPathComponent }
    public var recap: Recap { checkpoint.projectedRecap }
    public var transcript: SessionTranscript { SessionTranscript(sessionID: sessionID, messages: messages, recap: recap) }
    public var bytesRead: Int
}

public enum HistoryEvent: Sendable {
    case updated(HistoryUpdate)
    /// `sessionFiles` 是此刻全部会话文件：不在其中的旧索引（文件已删除的）可以丢掉；只回填了一部分（`HistoryScope.sessions`）为 nil，
    /// 不能据此丢
    case backfillFinished(sessionFiles: [URL]?)
}

/// 一家 Agent 的哪些会话归 CuePad 管：接入了的是全部（会话目录整个回填）；没接入的只有 CuePad 托管过的
/// （`CueStore.hostedSessionIDs`），终端里开的不回填。接入的含义只在这里：索引按它。
public enum HistoryScope: Sendable, Equatable {
    case all
    case sessions(Set<String>)

    public func covers(sessionID: String) -> Bool {
        switch self {
        case .all: true
        case .sessions(let ids): ids.contains(sessionID.lowercased())
        }
    }
}

/// Pi 的会话文件是 v3 树结构：当前分支 = 从文件最后一个条目沿 `parentId` 回溯到根，与 Pi 加载会话时确定叶子的规则一致。
public enum History {
    private static let fingerprintPrefix = 256
    private static let blockSize = 8 * 1024 * 1024

    /// 文件不存在时抛错——会话文件在第一条消息落盘前并不存在，调用方等文件出现再来。
    ///
    /// 你的消息里的图片当场存进 `files`（按内容哈希，已有的不重写），对话里只留 `![](cuepad://file/<键>)`：会话文件是图片唯一的来源，
    /// 终端里贴的图片附件目录里原本没有。不是图片的块跳过；存不下（磁盘错误）时抛错，不留一条缺图的消息。
    ///
    /// `transcript` 为 false 时不要对话（7 天外的会话）：照样逐行读出检查点，丢掉对话、不存图片（工具结果行不做 JSON 解码，
    /// 600 MB 的 Pi 会话文件实测不到 1 秒，不另做只读摘要的快速路径——那会是第二份轮次规则）。
    public static func index(
        file: URL, agent: AgentKind, from checkpoint: HistoryCheckpoint?, transcript wanted: Bool = true, modified: Date? = nil,
        files: AttachmentFiles
    ) throws -> HistoryUpdate {
        guard let format = agent.facts.sessionFiles else { preconditionFailure("\(agent.name) 的会话不在文件里") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        let resumed = try checkpoint.flatMap { try isResumable($0, handle: handle, size: size) ? $0 : nil }
        var state = resumed ?? HistoryCheckpoint()
        if state.cwd == nil { state.cwd = format.cwd(of: file) }
        let start = state.offset
        var transcript = Transcript(fallbackID: format.sessionID(of: file), files: wanted ? files : nil, file: file)
        let consumed = try forEachLine(handle, from: start, size: size) { line in try format.ingest(line, &state, &transcript) }
        if !wanted { transcript.messages = [] }
        if let sidecar = format.sidecar {
            let named = sidecar.file(file)
            state.sidecarModified = HistoryIndexer.modified(named)
            if let data = try? Data(contentsOf: named), let name = sidecar.name(data, state.sessionID ?? format.sessionID(of: file)) { state.name = name }
        }
        state.offset = consumed
        state.modified = modified
        try refreshFingerprint(&state, handle: handle)
        let history = SessionHistory(
            sessionID: state.sessionID, cwd: state.cwd, name: state.name, firstMessage: state.firstMessage, lastActivity: state.lastActivity,
            model: state.model, thinking: state.thinking)
        return HistoryUpdate(
            file: file, agent: agent, checkpoint: state, history: history, messages: transcript.messages, includesTranscript: wanted,
            renamed: state.name != resumed?.name, bytesRead: Int(consumed - start))
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
                        consumed += UInt64(piece.count + 1)
                        try body(piece)
                    } else {
                        carry.append(contentsOf: piece)
                        consumed += UInt64(carry.count + 1)
                        try carry.withUnsafeBytes { try body($0) }
                    }
                    carry.removeAll(keepingCapacity: true)
                    position = end + 1
                }
            }
        }
        return consumed
    }

    /// 文件被 Pi 改写（版本迁移）或替换后，旧偏移指向的可能是半行：检查文件没变短、开头没变、偏移落在换行之后。
    private static func isResumable(_ cp: HistoryCheckpoint, handle: FileHandle, size: UInt64) throws -> Bool {
        guard cp.offset <= size else { return false }
        if cp.offset == 0 { return true }
        try handle.seek(toOffset: cp.offset - 1)
        guard try handle.read(upToCount: 1) == Data([0x0A]) else { return false }
        return try fingerprint(handle, length: cp.fingerprintLength) == cp.fingerprint
    }

    private static func refreshFingerprint(_ cp: inout HistoryCheckpoint, handle: FileHandle) throws {
        cp.fingerprintLength = Int(min(UInt64(fingerprintPrefix), cp.offset))
        cp.fingerprint = try fingerprint(handle, length: cp.fingerprintLength)
    }

    private static func fingerprint(_ handle: FileHandle, length: Int) throws -> UInt64 {
        try handle.seek(toOffset: 0)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in try handle.read(upToCount: length) ?? Data() { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    struct Entry {
        var id: String
        var seq: Int64
        var at: Date
    }

    /// `files` 是你的消息里的图片要存进的附件目录；nil 是只为推出检查点状态而重放的行（消息丢弃，不存图片）。
    struct Transcript {
        let fallbackID: String
        let files: AttachmentFiles?
        /// 读的会话文件（不在文件里的为 nil）：dsh 的图片按它找到所在的 dsh 目录
        var file: URL? = nil
        var messages: [ChatMessage] = []

        mutating func add(
            _ cp: HistoryCheckpoint, _ entry: Entry, role: ChatRole, text: String, tools: ChatMessage.Tools? = nil,
            roundStartedAt: Date? = nil, deliveryID: String? = nil
        ) {
            messages.append(ChatMessage(
                sessionID: cp.sessionID ?? fallbackID, entryID: entry.id, seq: entry.seq, role: role, text: text, at: entry.at, tools: tools,
                roundStartedAt: roundStartedAt, deliveryID: deliveryID.flatMap(UUID.init(uuidString:))))
        }

        func said() -> Said { Said(files: files) }

        func toolImages(_ images: [Data?]) throws -> [String] {
            guard let files else { return [] }
            return try images.compactMap { data in try data.flatMap { try ToolImage.store($0, in: files) } }
        }
    }

    /// `text` 是文字块用换行连接（标题、摘要、机器消息判断都用它），`stored` 是文字与图片按块的原顺序拼成的正文格式（`CueFormat`，
    /// 与投送请求的 content 同一种；不存图片时等同 `text`）。
    struct Said {
        fileprivate let files: AttachmentFiles?
        private var texts: [String] = []
        private var pieces: [String] = []

        fileprivate init(files: AttachmentFiles?) { self.files = files }

        /// 交给 Agent 的附件行（`AttachmentFiles.agentLine`）认回文件引用：正文里是文件，标题与摘要里是文件名。
        mutating func text(_ block: String?) {
            let text = SessionName.withoutImageNotes(block ?? "")
            guard !text.isEmpty else { return }
            texts.append(AttachmentFiles.namingAgentLines(in: text))
            if let files { pieces.append(files.restoringAgentLines(in: text)) }
        }

        mutating func restore(text: String, stored: String) {
            texts = text.isEmpty ? [] : [text]
            pieces = stored.isEmpty ? [] : [stored]
        }

        mutating func image(_ data: Data?) throws {
            guard let files, let data, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return }
            pieces.append(CueFormat.imageMarkup(key: try files.store(data)))
        }

        var text: String { texts.joined(separator: "\n") }
        var stored: String { files == nil ? text : pieces.joined(separator: "\n") }
    }

    static func clip(_ text: String, _ limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.clipped(limit)
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) } })
            .joined(separator: " ")
    }
}
#endif
