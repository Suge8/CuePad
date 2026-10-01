#if os(macOS)
import Foundation

/// 会话列表要的摘要：会话 id、工作目录、名字、当前分支的首条 prompt（名字为空时作标题）、最后活动时间。
/// 原文留在会话文件里，这里不复制。
public struct PiSessionHistory: Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var name: String?
    /// 当前分支上第一条用户消息的文字（去掉首尾空白，最多 `PiHistory.promptPreviewLimit` 字）。
    public var firstPrompt: String?
    public var lastActivity: Date?
}

/// 增量索引的可持久化状态。调用方存起来（Codable），下次传回来就只读新增字节。
/// 只存得出摘要所需的：每个条目沿分支回溯到的首条 prompt（条目 id → `firstPrompts` 下标），不存正文。
public struct PiHistoryCheckpoint: Sendable, Codable, Equatable {
    /// 已消费到的字节偏移（总在一个换行之后）
    public internal(set) var offset: UInt64 = 0
    var fingerprint: UInt64 = 0
    var fingerprintLength = 0
    var sessionID: String?
    var cwd: String?
    var name: String?
    var lastActivity: Date?
    var leaf: String?
    var firstPrompts: [String] = []
    /// 其分支上已有用户消息的条目；不在表里的条目之前还没有 prompt。
    var promptOf: [String: Int] = [:]
}

public struct PiHistoryUpdate: Sendable {
    public var file: URL
    public var checkpoint: PiHistoryCheckpoint
    public var history: PiSessionHistory
    /// 这次新消费的字节数（半行不算）
    public var bytesRead: Int
}

public enum PiHistoryEvent: Sendable {
    case updated(PiHistoryUpdate)
    /// 首次回填（按修改时间倒序）全部完成；之后只有文件变化触发的 `updated`
    case backfillFinished
}

/// Pi 会话文件（JSONL，v3 树结构）的解析。当前分支 = 从文件最后一个条目沿 `parentId` 回溯到根，
/// 与 Pi 加载会话时确定叶子的规则一致。
public enum PiHistory {
    public static let promptPreviewLimit = 80

    private static let fingerprintPrefix = 256
    private static let blockSize = 8 * 1024 * 1024

    /// 从检查点继续索引 `file`（没有检查点或检查点已失效则从头）。文件不存在时抛错——
    /// 会话文件在第一条消息落盘前并不存在，调用方等文件出现再来。
    public static func index(file: URL, from checkpoint: PiHistoryCheckpoint?) throws -> PiHistoryUpdate {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        var state = try checkpoint.flatMap { try isResumable($0, handle: handle, size: size) ? $0 : nil } ?? PiHistoryCheckpoint()
        let start = state.offset

        try handle.seek(toOffset: start)
        var carry = Data()
        var consumed = start
        var block = [UInt8](repeating: 0, count: blockSize)
        while true {
            let n = read(handle.fileDescriptor, &block, block.count)
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            carry.append(contentsOf: block[0..<n])
            var lineStart = carry.startIndex
            while let newline = carry[lineStart...].firstIndex(of: 0x0A) {
                ingest(carry[lineStart..<newline], into: &state)
                lineStart = carry.index(after: newline)
            }
            consumed += UInt64(carry.distance(from: carry.startIndex, to: lineStart))
            carry = Data(carry[lineStart...])
        }
        state.offset = consumed
        try refreshFingerprint(&state, handle: handle)
        return PiHistoryUpdate(file: file, checkpoint: state, history: history(of: state), bytesRead: Int(consumed - start))
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
    }

    private struct Message: Decodable {
        var role: String
        var content: Content?
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        struct Block: Decodable { var type: String; var text: String? }

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
        }

        var text: String {
            switch self {
            case .text(let s): s
            case .blocks(let b): b.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            }
        }
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// toolResult 行占会话体积的绝大部分（工具输出、图片），又不含 prompt：只从行首取 id/parentId 挂进树，
    /// 不做完整 JSON 解码。Pi 写出的键序固定为 type, id, parentId, timestamp, message。
    private static let toolResultMarker = Data(#""role":"toolResult""#.utf8)
    private static let headLength = 512

    private static func ingestToolResult(_ raw: Data, into cp: inout PiHistoryCheckpoint) -> Bool {
        let head = raw.prefix(headLength)
        guard raw.count > headLength, head.range(of: toolResultMarker) != nil,
              case .string(let id) = field("id", in: head) else { return false }
        let parent: String?
        switch field("parentId", in: head) {
        case .string(let value): parent = value
        case .null: parent = nil
        case .missing: return false
        }
        attach(id, to: parent, in: &cp)
        return true
    }

    private enum Field { case missing, null, string(String) }

    /// `"key":"value"` 或 `"key":null`
    private static func field(_ key: String, in head: Data) -> Field {
        guard let r = head.range(of: Data("\"\(key)\":".utf8)) else { return .missing }
        let rest = head[r.upperBound...]
        if rest.starts(with: Data("null".utf8)) { return .null }
        guard rest.first == 0x22, let end = rest.dropFirst().firstIndex(of: 0x22) else { return .missing }
        return .string(String(decoding: rest[rest.index(after: rest.startIndex)..<end], as: UTF8.self))
    }

    private static func ingest(_ raw: Data, into cp: inout PiHistoryCheckpoint) {
        if ingestToolResult(raw, into: &cp) { return }
        guard !raw.isEmpty, let line = try? decoder.decode(Line.self, from: raw) else { return } // 损坏行跳过
        let time = line.timestamp.flatMap { try? Date($0, strategy: timestampStyle) }
        if let time { cp.lastActivity = max(cp.lastActivity ?? time, time) }
        if line.type == "session" {
            cp.sessionID = line.id
            cp.cwd = line.cwd
            return
        }
        guard let id = line.id else { return }
        if line.type == "session_info" { cp.name = line.name }
        attach(id, to: line.parentId, in: &cp)
        if cp.promptOf[id] == nil, line.type == "message", let message = line.message, message.role == "user" {
            let text = (message.content?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cp.promptOf[id] = cp.firstPrompts.count
            cp.firstPrompts.append(String(text.prefix(promptPreviewLimit)))
        }
    }

    /// 新条目沿用父条目所在分支的首条 prompt，并成为当前叶子（当前分支 = 文件最后一个条目沿 parentId 回溯到根）。
    private static func attach(_ id: String, to parent: String?, in cp: inout PiHistoryCheckpoint) {
        if let parent, let prompt = cp.promptOf[parent] { cp.promptOf[id] = prompt }
        cp.leaf = id
    }

    private static let decoder = JSONDecoder()

    static func history(of cp: PiHistoryCheckpoint) -> PiSessionHistory {
        PiSessionHistory(
            sessionID: cp.sessionID, cwd: cp.cwd, name: cp.name,
            firstPrompt: cp.leaf.flatMap { cp.promptOf[$0] }.map { cp.firstPrompts[$0] }, lastActivity: cp.lastActivity)
    }
}
#endif
