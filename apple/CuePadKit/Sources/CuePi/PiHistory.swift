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

/// 增量索引的可持久化状态。调用方存起来（Codable），下次传回来就只读新增字节。只存摘要所需的，不存正文。
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
            case .blocks(let b): b.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: " ")
            }
        }
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// toolResult 行占会话体积的绝大部分（工具输出、图片），又不含摘要要的东西：认出来就跳过，不做 JSON 解码。
    /// Pi 写出的键序固定为 type, id, parentId, timestamp, message，角色在行首附近。
    private static let toolResultMarker = Data(#""role":"toolResult""#.utf8)
    private static let headLength = 512

    private static func ingest(_ raw: Data, into cp: inout PiHistoryCheckpoint) {
        if raw.count > headLength, raw.prefix(headLength).range(of: toolResultMarker) != nil { return }
        guard !raw.isEmpty, let line = try? decoder.decode(Line.self, from: raw) else { return } // 损坏行跳过
        let time = line.timestamp.flatMap { try? Date($0, strategy: timestampStyle) }
        if let time { cp.lastActivity = max(cp.lastActivity ?? time, time) }
        switch line.type {
        case "session":
            cp.sessionID = line.id
            cp.cwd = line.cwd
        case "session_info":
            cp.name = line.name
        case "message" where cp.firstMessage == nil && line.message?.role == "user":
            let text = line.message?.content?.text ?? ""
            if !text.isEmpty { cp.firstMessage = String(text.prefix(PiSessionName.firstMessageLimit)) }
        default:
            break
        }
    }

    private static let decoder = JSONDecoder()

    static func history(of cp: PiHistoryCheckpoint) -> PiSessionHistory {
        PiSessionHistory(
            sessionID: cp.sessionID, cwd: cp.cwd, name: cp.name, firstMessage: cp.firstMessage, lastActivity: cp.lastActivity)
    }
}
#endif
