#if os(macOS)
import CuePi
import CueStore
import Foundation

/// Pi 历史索引的落盘：会话行与检查点都存在 Store（本机表），检查点按会话 id 存放。
/// 索引器按文件查检查点，所以这里维护"文件路径 → 会话 id"。
actor PiHistoryPersistence {
    private static let titleLimit = 80

    private let store: CueStore
    private var idsByPath: [String: String]?

    init(store: CueStore) {
        self.store = store
    }

    func checkpoint(for file: URL) async -> PiHistoryCheckpoint? {
        guard let id = await sessionIDs()[file.path],
              let data = try? await store.piCheckpoint(of: id)
        else { return nil }
        return try? JSONDecoder().decode(PiHistoryCheckpoint.self, from: data)
    }

    /// 会话行与检查点在同一事务里写入：中途失败时下次从旧检查点重读，不会漏掉内容。
    func persist(_ update: PiHistoryUpdate) async throws {
        let history = update.history
        let firstPrompt = history.turns.first?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.titleLimit)
        let modified = try? update.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let session = StoredPiSession(
            id: history.sessionID ?? update.file.deletingPathExtension().lastPathComponent,
            path: update.file.path,
            cwd: history.cwd ?? "",
            title: history.name ?? firstPrompt.map(String.init) ?? "",
            lastActivityAt: history.lastActivity ?? modified ?? .distantPast)
        try await store.upsertPiSession(session, checkpoint: JSONEncoder().encode(update.checkpoint))
        idsByPath?[session.path] = session.id
    }

    private func sessionIDs() async -> [String: String] {
        if let idsByPath { return idsByPath }
        let rows = (try? await store.piSessions()) ?? []
        let loaded = Dictionary(rows.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        idsByPath = loaded
        return loaded
    }
}
#endif
