#if os(macOS)
import CuePi
import CueStore
import Foundation
import os

/// Pi 历史索引的落盘：会话行与检查点都存在 Store（本机表），检查点按会话 id 存放；同一次读出的对话与摘要在同一事务里写
/// （对话只写最近 `transcriptWindow` 内活跃过的会话，更早的按需补写，见投送方式 `transcript`）。文件一变化就写，不节流：
/// Mac 本机界面也读同步记录，这里的延迟就是 Mac 上看到的延迟。
/// 索引器按文件查检查点，所以这里维护"文件路径 → 会话 id"。
///
/// Store 读写失败时，该文件的索引不再写回：库异常时反复重写只会放大问题。失败作为错误抛给调用方报告。
/// 检查点解码失败（格式随 CuePi 升级失效）是合法的"从头重读"：记日志后当作没有检查点。
actor PiHistoryPersistence {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "pi-history")
    /// 自动同步对话的范围：这么久之内活跃过的会话；对话也在会话安静这么久之后清理
    static let transcriptWindow: TimeInterval = 7 * 86_400

    private let storage: CueStore
    /// 这台 Mac：会话文件索引也写成这台 Mac 的会话同步记录（见 `CueStore.upsertPiSession`）。
    private let host: String
    private var idsByPath: [String: String]?
    private var blocked: Set<String> = []

    init(storage: CueStore, host: String) {
        self.storage = storage
        self.host = host
    }

    /// Store 读取失败时抛错，并停止该文件的写回；没有检查点或检查点已失效返回 nil。
    func checkpoint(for file: URL) async throws -> PiHistoryCheckpoint? {
        let data: Data?
        do {
            guard let id = try await sessionIDs()[file.path] else { return nil }
            data = try await storage.piCheckpoint(of: id)
        } catch {
            blocked.insert(file.path)
            throw error
        }
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(PiHistoryCheckpoint.self, from: data)
        } catch {
            Self.log.notice("检查点无法解码，从头重读 \(file.path, privacy: .public)：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 会话行与检查点在同一事务里写入：中途失败时下次从旧检查点重读，不会漏掉内容。
    func persist(_ update: PiHistoryUpdate) async throws {
        guard !blocked.contains(update.file.path) else { return }
        let history = update.history
        let modified = try? update.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let session = StoredPiSession(
            id: history.sessionID ?? update.file.deletingPathExtension().lastPathComponent,
            path: update.file.path,
            cwd: history.cwd ?? "",
            title: history.displayName,
            lastActivityAt: history.lastActivity ?? modified ?? .distantPast)
        do {
            let transcript = try await transcript(of: update, sessionID: session.id, lastActivity: session.lastActivityAt)
            try await storage.upsertPiSession(
                session, checkpoint: JSONEncoder().encode(update.checkpoint), host: host, transcript: transcript)
        } catch {
            blocked.insert(update.file.path)
            throw error
        }
        idsByPath?[session.path] = session.id
    }

    /// 这次读到的对话与摘要。会话在范围外时只写摘要；刚进入范围（本机还没有它的对话，而这次是增量读）时从头再读一遍，
    /// 补齐全部消息——"范围内的会话有全部消息"不靠读到的那一段碰巧完整。
    private func transcript(of update: PiHistoryUpdate, sessionID: String, lastActivity: Date) async throws -> PiTranscript {
        guard lastActivity > Date.now.addingTimeInterval(-Self.transcriptWindow) else {
            return PiTranscript(update, sessionID: sessionID, messages: false)
        }
        let incremental = update.checkpoint.offset > UInt64(update.bytesRead)
        if incremental, try await storage.piMessages(of: sessionID).isEmpty {
            return PiTranscript(try PiHistory.index(file: update.file, from: nil), sessionID: sessionID)
        }
        return PiTranscript(update, sessionID: sessionID)
    }

    /// 清理安静了的会话的对话：现在一次，之后每天一次，直到任务取消。清理失败记日志，下次再来。
    func keepPruned(timing: Timing = .system) async {
        repeat {
            do {
                try await storage.prunePiMessages(olderThan: Self.transcriptWindow, now: timing.now())
            } catch {
                Self.log.error("清理对话失败：\(String(describing: error), privacy: .public)")
            }
        } while (try? await timing.sleep(.seconds(86_400))) != nil
    }

    /// 回填完成：只留下此刻的会话文件。
    func retain(_ files: [URL]) async throws {
        let paths = Set(files.map(\.path))
        let started = ContinuousClock.now
        let removed = try await storage.retainPiSessions(paths: paths, host: host)
        idsByPath = idsByPath?.filter { paths.contains($0.key) }
        if removed > 0 {
            Self.log.notice("回填完成：删掉 \(removed) 条不在会话列表里的旧索引，用时 \(ContinuousClock.now - started, privacy: .public)")
        }
    }

    private func sessionIDs() async throws -> [String: String] {
        if let idsByPath { return idsByPath }
        let rows = try await storage.piSessions()
        let loaded = Dictionary(rows.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        idsByPath = loaded
        return loaded
    }
}

nonisolated extension PiTranscript {
    /// 读会话文件得到的对话与摘要；`messages` 为 false 时只要摘要（范围外的会话）。
    init(_ update: PiHistoryUpdate, sessionID: String, messages: Bool = true) {
        let recap = update.recap
        self.init(
            sessionID: sessionID,
            messages: messages ? update.transcript.map { PiChatMessage($0, sessionID: sessionID) } : [],
            recap: PiRecap(lastPrompt: recap.lastPrompt, lastReply: recap.lastReply, pendingPrompt: recap.pendingPrompt))
    }
}

nonisolated extension PiChatMessage {
    init(_ entry: PiTranscriptEntry, sessionID: String) {
        self.init(
            sessionID: sessionID, entryID: entry.entryID, seq: entry.seq, role: entry.role == .user ? .user : .pi, text: entry.text,
            at: entry.at, toolCount: entry.toolCount, roundStartedAt: entry.roundStartedAt,
            deliveryID: entry.deliveryID.flatMap(UUID.init(uuidString:)))
    }
}
#endif
