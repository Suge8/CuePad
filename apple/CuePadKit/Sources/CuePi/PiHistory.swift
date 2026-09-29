import Foundation

public enum PiTurnStatus: Sendable, Equatable, Codable {
    case inProgress, completed, aborted, failed
}

/// 一轮：用户 prompt → 最终回复。文字只是预览（前 `PiHistory.previewLimit` 个字符），原文留在会话文件里。
public struct PiTurn: Sendable, Equatable {
    public var id: String
    public var prompt: String
    public var promptImageCount: Int
    public var promptedAt: Date?
    /// 这一轮里最后一条 assistant 消息的文字（没有文字时为 nil）
    public var reply: String?
    public var repliedAt: Date?
    public var status: PiTurnStatus
    public var failure: String?
}

public struct PiSessionHistory: Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var name: String?
    /// 沿当前分支，时间正序
    public var turns: [PiTurn]
    public var lastActivity: Date?
}

/// 增量索引的可持久化状态。调用方存起来（Codable），下次传回来就只读新增字节。
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
    var entries: [Entry] = []

    struct Entry: Sendable, Codable, Equatable {
        enum Role: String, Codable, Sendable { case other, user, assistant }
        var id: String
        var parent: String?
        var role: Role
        var time: Date?
        var text: String?
        var images: Int
        var stopReason: String?
        var error: String?
    }
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
    public static let previewLimit = 1000

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
        var index = Dictionary(uniqueKeysWithValues: state.entries.enumerated().map { ($1.id, $0) })

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
                ingest(carry[lineStart..<newline], into: &state, index: &index)
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
        var stopReason: String?
        var errorMessage: String?
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

        var imageCount: Int {
            if case .blocks(let b) = self { b.filter { $0.type == "image" }.count } else { 0 }
        }
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// toolResult 行占会话体积的绝大部分（工具输出、图片），又不含 prompt/回复：只从行首取 id/parentId 挂进树，
    /// 不做完整 JSON 解码。Pi 写出的键序固定为 type, id, parentId, timestamp, message。
    private static let toolResultMarker = Data(#""role":"toolResult""#.utf8)
    private static let headLength = 512

    private static func ingestToolResult(_ raw: Data, into cp: inout PiHistoryCheckpoint, index: inout [String: Int]) -> Bool {
        let head = raw.prefix(headLength)
        guard raw.count > headLength, head.range(of: toolResultMarker) != nil,
              case .string(let id) = field("id", in: head) else { return false }
        let parent: String?
        switch field("parentId", in: head) {
        case .string(let value): parent = value
        case .null: parent = nil
        case .missing: return false
        }
        index[id] = cp.entries.count
        cp.entries.append(PiHistoryCheckpoint.Entry(id: id, parent: parent, role: .other, time: nil, images: 0))
        cp.leaf = id
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

    private static func ingest(_ raw: Data, into cp: inout PiHistoryCheckpoint, index: inout [String: Int]) {
        if ingestToolResult(raw, into: &cp, index: &index) { return }
        guard !raw.isEmpty, let line = try? JSONDecoder().decode(Line.self, from: raw) else { return } // 损坏行跳过
        let time = line.timestamp.flatMap { try? Date($0, strategy: timestampStyle) }
        if let time { cp.lastActivity = max(cp.lastActivity ?? time, time) }
        if line.type == "session" {
            cp.sessionID = line.id
            cp.cwd = line.cwd
            return
        }
        guard let id = line.id else { return }
        if line.type == "session_info" { cp.name = line.name }

        var entry = PiHistoryCheckpoint.Entry(id: id, parent: line.parentId, role: .other, time: time, images: 0)
        if line.type == "message", let m = line.message {
            switch m.role {
            case "user":
                entry.role = .user
                entry.text = preview(m.content?.text ?? "")
                entry.images = m.content?.imageCount ?? 0
            case "assistant":
                entry.role = .assistant
                entry.text = m.content.map { preview($0.text) }.flatMap { $0.isEmpty ? nil : $0 }
                entry.stopReason = m.stopReason
                entry.error = m.errorMessage
            default: break
            }
        }
        index[id] = cp.entries.count
        cp.entries.append(entry)
        cp.leaf = id
    }

    private static func preview(_ text: String) -> String { String(text.prefix(previewLimit)) }

    // MARK: 当前分支 → 轮

    static func history(of cp: PiHistoryCheckpoint) -> PiSessionHistory {
        let byID = Dictionary(uniqueKeysWithValues: cp.entries.map { ($0.id, $0) })
        var path: [PiHistoryCheckpoint.Entry] = []
        var cursor = cp.leaf
        while let id = cursor, let entry = byID[id] {
            path.append(entry)
            cursor = entry.parent
        }

        var turns: [PiTurn] = []
        var lastStop: [String?] = []
        for entry in path.reversed() {
            switch entry.role {
            case .user:
                turns.append(PiTurn(id: entry.id, prompt: entry.text ?? "", promptImageCount: entry.images,
                                    promptedAt: entry.time, status: .inProgress))
                lastStop.append(nil)
            case .assistant where !turns.isEmpty:
                turns[turns.count - 1].reply = entry.text
                turns[turns.count - 1].repliedAt = entry.time
                turns[turns.count - 1].failure = entry.error
                lastStop[lastStop.count - 1] = entry.stopReason ?? ""
            default: break
            }
        }
        for i in turns.indices {
            turns[i].status = status(stopReason: lastStop[i], isLast: i == turns.count - 1)
        }
        return PiSessionHistory(sessionID: cp.sessionID, cwd: cp.cwd, name: cp.name, turns: turns, lastActivity: cp.lastActivity)
    }

    /// 没有 assistant 回复或停在工具调用上：最后一轮视为进行中，之后又有新 prompt 的视为被打断。
    private static func status(stopReason: String?, isLast: Bool) -> PiTurnStatus {
        switch stopReason {
        case "error": .failed
        case "aborted": .aborted
        case nil, "toolUse": isLast ? .inProgress : .aborted
        default: .completed
        }
    }
}
