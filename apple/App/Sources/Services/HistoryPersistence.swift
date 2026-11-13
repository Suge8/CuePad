#if os(macOS)
import CueBridge
import CueStore
import Foundation
import os

/// 会话行与检查点都存在 Store（本机表）；同一次读出的对话与摘要在同一事务里写。
/// 首次回填按批写（`AppServices.backfillBatch`），之后文件一变化就写，不节流：Mac 本机界面也读同步记录，这里的延迟就是 Mac 上看到的延迟。
///
/// Store 读写失败时，该文件的索引不再写回：库异常时反复重写只会放大问题。失败作为错误抛给调用方报告。
/// 检查点解码失败（格式随 CueBridge 升级失效）是合法的"从头重读"：当作没有检查点，有这种文件时回填完成汇总记一行。
actor HistoryPersistence {
    private static let log = Logger(subsystem: AppIdentity.id, category: "pi-history")
    private let storage: CueStore
    /// 这台 Mac：会话文件索引也写成这台 Mac 的会话同步记录（见 `CueStore.upsertSession`）。
    private let host: String
    private var starts: [String: IndexedSessionStart]?
    private var blocked: Set<String> = []
    /// 回填期间检查点格式已过期（CueBridge 升级）、从头重读的文件数与回填开始的时刻：不为 0 时回填完成汇总记一行
    private var outdated = 0
    private var backfillStarted: ContinuousClock.Instant?

    init(storage: CueStore, host: String) {
        self.storage = storage
        self.host = host
    }

    /// 回填开始（列目录、取修改时间之前）：汇总日志的用时从这里算。
    func beginBackfill() {
        if backfillStarted == nil { backfillStarted = .now }
    }

    /// Store 读取失败时抛错，并停止该文件的写回。
    func start(for file: URL) async throws -> HistoryStart? {
        let known: IndexedSessionStart?
        do {
            known = try await loadedStarts()[file.path]
        } catch {
            blocked.insert(file.path)
            throw error
        }
        guard let known else { return nil }
        var checkpoint: HistoryCheckpoint?
        if let data = known.checkpoint {
            do { checkpoint = try JSONDecoder().decode(HistoryCheckpoint.self, from: data) } catch { outdated += 1 }
        }
        return HistoryStart(checkpoint: checkpoint, hasTranscript: known.hasMessages)
    }

    /// 一批更新在同一事务里写入（会话行、检查点与对话）：中途失败时下次从旧检查点重读，不会漏掉内容。
    /// 整批写不进去时逐个重写，只有真正写不进去的文件不再写回；返回它们与原因。
    func persist(_ updates: [HistoryUpdate]) async -> [(file: URL, error: any Error)] {
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

    private func write(_ updates: [HistoryUpdate]) async throws {
        let batch = try updates.map { update in
            let history = update.history
            let session = IndexedSession(
                id: update.sessionID,
                path: update.file.path,
                cwd: history.cwd ?? "",
                title: history.displayName,
                lastActivityAt: history.lastActivity ?? update.checkpoint.modified ?? .distantPast,
                agent: update.agent, model: history.model, thinking: history.thinking)
            return SessionUpsert(session: session, checkpoint: try JSONEncoder().encode(update.checkpoint), transcript: update.transcript)
        }
        try await storage.upsertSessions(batch, host: host)
        for (item, update) in zip(batch, updates) {
            let previous = starts?[item.session.path].flatMap { $0.id == item.session.id ? $0 : nil }
            starts?[item.session.path] = IndexedSessionStart(
                id: item.session.id, checkpoint: item.checkpoint, hasMessages: previous?.hasMessages == true || update.includesTranscript)
        }
    }

    func keepPruned(timing: Timing = .system) async {
        repeat {
            do {
                try await storage.pruneMessages(olderThan: Chat.transcriptWindow, now: timing.now())
            } catch {
                Self.log.error("清理对话失败：\(String(describing: error))")
            }
        } while (try? await timing.sleep(.seconds(86_400))) != nil
    }

    /// 一个 Agent 的回填完成：回填的是整个目录（`files` 不为 nil）时它的索引只留下此刻的会话文件（别家的不动），返回 true——
    /// 调用方接着对账托管会话的记录。
    func backfillFinished(_ files: [URL]?, of agent: AgentKind) async throws -> Bool {
        if let backfillStarted {
            if outdated > 0 {
                Self.log.notice(
                    "回填完成：\(agent.rawValue, privacy: .public) \(files.map { "\($0.count) 个会话文件" } ?? "托管过的会话", privacy: .public)，\(self.outdated) 个检查点格式已过期、从头重读，用时 \(ContinuousClock.now - backfillStarted, privacy: .public)")
            }
            self.backfillStarted = nil
            outdated = 0
        }
        guard let files else { return false }
        let paths = Set(files.map(\.path))
        let started = ContinuousClock.now
        let removed = try await storage.retainSessions(paths: paths, agent: agent, host: host)
        if removed > 0 {
            // 删掉的那几条不再是"索引过"：下次要时从 Store 重读
            starts = nil
            Self.log.notice("回填完成：删掉 \(removed) 条不在会话列表里的旧索引，用时 \(ContinuousClock.now - started, privacy: .public)")
        }
        return true
    }

    /// 同步记录不动；这台 Mac 托管过的会话留着（`CueStore.deleteSessions`），下次接入从头回填。
    func forget(_ agent: AgentKind) async throws {
        try await storage.deleteSessions(of: agent, keepingHostedOn: host)
        starts = nil
    }

    func hostedScope(of agent: AgentKind) async throws -> HistoryScope {
        .sessions(try await storage.hostedSessionIDs(of: agent, host: host))
    }

    private func loadedStarts() async throws -> [String: IndexedSessionStart] {
        if let starts { return starts }
        let loaded = try await storage.indexStarts()
        starts = loaded
        return loaded
    }
}
#endif
