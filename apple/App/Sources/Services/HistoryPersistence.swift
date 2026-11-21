#if os(macOS)
import CueBridge
import CueStore
import Foundation
import os

actor HistoryPersistence {
    private static let log = Logger(subsystem: AppIdentity.id, category: "pi-history")
    private let storage: CueStore
    private let host: String
    private var starts: [String: IndexedSessionStart]?
    private var blocked: Set<String> = []
    private var outdated = 0
    private var backfillStarted: ContinuousClock.Instant?

    init(storage: CueStore, host: String) {
        self.storage = storage
        self.host = host
    }

    func beginBackfill() {
        if backfillStarted == nil { backfillStarted = .now }
    }

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

    func keepPruned(timing: Timing) async {
        repeat {
            do {
                try await storage.pruneMessages(olderThan: Chat.transcriptWindow, now: timing.now())
            } catch {
                Self.log.error("清理对话失败：\(String(describing: error))")
            }
        } while (try? await timing.sleep(.seconds(86_400))) != nil
    }

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
            starts = nil
            Self.log.notice("回填完成：删掉 \(removed) 条不在会话列表里的旧索引，用时 \(ContinuousClock.now - started, privacy: .public)")
        }
        return true
    }

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
