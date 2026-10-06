#if os(macOS)
import CuePi
import CueStore
import Foundation
import os

/// Pi 历史索引的落盘：会话行与检查点都存在 Store（本机表），检查点按会话 id 存放；同一次读出的对话与摘要在同一事务里写
/// （对话只写最近 `transcriptWindow` 内活跃过的会话，更早的按需补写，见投送方式 `transcript`）。首次回填按批写（`AppServices.backfillBatch`），之后文件一变化就写，不节流：
/// Mac 本机界面也读同步记录，这里的延迟就是 Mac 上看到的延迟。
/// 索引器按文件查检查点，所以这里维护"文件路径 → 会话 id"。
///
/// Store 读写失败时，该文件的索引不再写回：库异常时反复重写只会放大问题。失败作为错误抛给调用方报告。
/// 检查点解码失败（格式随 CuePi 升级失效）是合法的"从头重读"：当作没有检查点，回填完成时汇总记一行。
actor PiHistoryPersistence {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "pi-history")
    /// 自动同步对话的范围：这么久之内活跃过的会话；对话也在会话安静这么久之后清理
    static let transcriptWindow: TimeInterval = 7 * 86_400

    private let storage: CueStore
    /// 这台 Mac：会话文件索引也写成这台 Mac 的会话同步记录（见 `CueStore.upsertPiSession`）。
    private let host: String
    private var idsByPath: [String: String]?
    private var blocked: Set<String> = []
    /// 回填期间检查点格式已过期（CuePi 升级）、从头重读的文件数与回填开始的时刻：回填完成时汇总记一行
    private var outdated = 0
    private var backfillStarted: ContinuousClock.Instant?

    init(storage: CueStore, host: String) {
        self.storage = storage
        self.host = host
    }

    /// Store 读取失败时抛错，并停止该文件的写回；没有检查点或检查点已失效返回 nil。
    /// 回填开始（列目录、取修改时间之前）：汇总日志的用时从这里算。已经开始的不重设。
    func beginBackfill() {
        if backfillStarted == nil { backfillStarted = .now }
    }

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
            outdated += 1
            return nil
        }
    }

    /// 一批更新在同一事务里写入（会话行、检查点与对话）：中途失败时下次从旧检查点重读，不会漏掉内容。
    /// 整批写不进去时逐个重写，只有真正写不进去的文件不再写回；返回它们与原因。
    func persist(_ updates: [PiHistoryUpdate]) async -> [(file: URL, error: any Error)] {
        let updates = updates.filter { !blocked.contains($0.file.path) }
        guard !updates.isEmpty else { return [] }
        do {
            try await write(updates)
            return []
        } catch {
            guard updates.count > 1 else {
                blocked.insert(updates[0].file.path)
                return [(updates[0].file, error)]
            }
            var failures: [(file: URL, error: any Error)] = []
            for update in updates where !blocked.contains(update.file.path) {
                do {
                    try await write([update])
                } catch {
                    blocked.insert(update.file.path)
                    failures.append((update.file, error))
                }
            }
            return failures
        }
    }

    private func write(_ updates: [PiHistoryUpdate]) async throws {
        var batch: [PiSessionUpsert] = []
        for update in updates {
            let history = update.history
            let modified = try? update.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let session = StoredPiSession(
                id: history.sessionID ?? update.file.deletingPathExtension().lastPathComponent,
                path: update.file.path,
                cwd: history.cwd ?? "",
                title: history.displayName,
                lastActivityAt: history.lastActivity ?? modified ?? .distantPast)
            batch.append(PiSessionUpsert(
                session: session, checkpoint: try JSONEncoder().encode(update.checkpoint),
                transcript: try await transcript(of: update, sessionID: session.id)))
        }
        try await storage.upsertPiSessions(batch, host: host)
        for item in batch { idsByPath?[item.session.path] = item.session.id }
    }

    /// 这次读到的对话与摘要。在不在范围内只看读文件时的判定（索引器按文件修改时间，`includesTranscript`），这里不另判：
    /// 范围外只写摘要；刚进入范围（本机还没有它的对话，而这次是增量读）时从头再读一遍，补齐全部消息——
    /// "范围内的会话有全部消息"不靠读到的那一段碰巧完整。
    private func transcript(of update: PiHistoryUpdate, sessionID: String) async throws -> PiTranscript {
        guard update.includesTranscript else { return PiTranscript(update, sessionID: sessionID, messages: false) }
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
        if let backfillStarted {
            Self.log.notice(
                "回填完成：\(files.count) 个会话文件，其中 \(self.outdated) 个检查点格式已过期、从头重读，用时 \(ContinuousClock.now - backfillStarted, privacy: .public)")
            self.backfillStarted = nil
            outdated = 0
        }
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
