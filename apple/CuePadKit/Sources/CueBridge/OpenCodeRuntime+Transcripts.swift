#if os(macOS)
import CueStore
import Foundation
import OSLog

extension OpenCodeRuntime {
    static func path(_ sessionID: String) -> String { "opencode:\(sessionID)" }

    public func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> SessionTranscript {
        let hosted = try await store.hostedSessionIDs(of: .opencode, host: hostID)
        guard sessions[session.id] != nil || hosted.contains(session.id) else {
            throw BridgeError.unknownSession(session.id)
        }
        let connection = try await ensureService()
        let info = try await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(session.id)").data
        return try await OpenCodeHistory.read(connection.client, info, from: nil, files: files).transcript
    }

    /// `gone`：托管过、服务里已没有的会话，它们的索引删掉。
    func backfill(_ infos: [OpenCodeSessionInfo], gone: Set<String>, _ connection: Connection) async {
        do {
            let stored = Dictionary(
                try await store.indexedSessions().filter { $0.agent == .opencode }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard self.connection === connection else { return }  // 读的时候停下了（断开接入）：索引已删，不再写回
            var summaries: [SessionUpsert] = []
            let recent = Date().addingTimeInterval(-transcriptWindow)
            for info in infos {
                if let indexed = stored[info.id], abs(indexed.lastActivityAt.timeIntervalSince(info.updatedAt)) < 0.001 { continue }
                if info.updatedAt > recent {
                    enqueueIngest(info.id, urgent: false)
                } else {
                    summaries.append(SessionUpsert(session: indexed(info, firstMessage: nil), checkpoint: nil, transcript: nil))
                }
            }
            if !summaries.isEmpty { try await store.upsertSessions(summaries, host: hostID) }
            guard self.connection === connection else { return }
            await dropIndex(gone)
        } catch {
            Self.log.error("OpenCode 会话索引回填失败：\(String(describing: error), privacy: .public)")
        }
    }

    private func indexed(_ info: OpenCodeSessionInfo, firstMessage: String?) -> IndexedSession {
        IndexedSession(
            id: info.id, path: Self.path(info.id), cwd: info.location.directory,
            title: SessionName.display(name: info.title, firstMessage: firstMessage, folder: URL(filePath: info.location.directory).lastPathComponent),
            lastActivityAt: info.updatedAt, agent: .opencode)
    }

    /// 只删这几个会话的索引：索引里还有升级前留下的非托管会话，它们不在服务的托管列表里，也留着不动。
    func dropIndex(_ gone: Set<String>) async {
        do {
            let kept = try await store.indexedSessions().filter { $0.agent == .opencode && !gone.contains($0.id) }.map(\.path)
            try await store.retainSessions(paths: Set(kept), agent: .opencode, host: hostID)
        } catch {
            Self.log.error("OpenCode 会话索引对账失败：\(String(describing: error), privacy: .public)")
        }
    }

    func enqueueIngest(_ sessionID: String, urgent: Bool) {
        guard sessions[sessionID] != nil else { return }
        if let index = ingestQueue.firstIndex(of: sessionID) {
            guard urgent else { return }
            ingestQueue.remove(at: index)
        }
        if urgent { ingestQueue.insert(sessionID, at: 0) } else { ingestQueue.append(sessionID) }
        guard ingesting == nil else { return }
        ingesting = Task { [weak self] in
            while let self, !Task.isCancelled, !self.ingestQueue.isEmpty {
                let next = self.ingestQueue.removeFirst()
                await self.ingest(next)
            }
            if !Task.isCancelled { self?.ingesting = nil }  // 取消的是被 stop 换下的，不清掉新起的
        }
    }

    func checkpoint(of sessionID: String) async throws -> OpenCodeHistory.Checkpoint? {
        if let checkpoint = checkpoints[sessionID] { return checkpoint }
        return try await store.checkpoint(of: sessionID).flatMap { try? JSONDecoder().decode(OpenCodeHistory.Checkpoint.self, from: $0) }
    }

    private func ingest(_ sessionID: String) async {
        guard let connection else { return }
        do {
            let info = try await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(sessionID)").data
            let (next, transcript) = try await OpenCodeHistory.read(connection.client, info, from: try await checkpoint(of: sessionID), files: store.files)
            // 读的时候会话被删了：删除时已对过账，这里再写就把索引写回来了
            guard self.connection === connection, sessions[sessionID] != nil else { return }
            checkpoints[sessionID] = next
            try await store.upsertSessions(
                [SessionUpsert(
                    session: indexed(info, firstMessage: next.history.firstMessage), checkpoint: try JSONEncoder().encode(next),
                    transcript: transcript)],
                host: hostID)
            if self.connection === connection, sessions[sessionID]?.firstMessage == nil, let first = next.history.firstMessage {
                sessions[sessionID]?.firstMessage = first
                publish(sessionID)
            }
        } catch let error as OpenCodeAPIError where error.status == 404 {
            return  // 读的时候会话被删了：删除事件会对账
        } catch {
            Self.log.error("读 OpenCode 会话 \(sessionID, privacy: .public) 的对话失败：\(String(describing: error), privacy: .public)")
        }
    }
}
#endif
