#if os(macOS)
import CuePi
import CueStore
import Foundation
import os

/// Pi 历史索引的落盘：会话行与检查点都存在 Store（本机表），检查点按会话 id 存放。
/// 索引器按文件查检查点，所以这里维护"文件路径 → 会话 id"。
///
/// Store 读写失败时，该文件的索引不再写回：库异常时反复重写只会放大问题。失败作为错误抛给调用方报告。
/// 检查点解码失败（格式随 CuePi 升级失效）是合法的"从头重读"：记日志后当作没有检查点。
actor PiHistoryPersistence {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "pi-history")

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
            try await storage.upsertPiSession(session, checkpoint: JSONEncoder().encode(update.checkpoint), host: host)
        } catch {
            blocked.insert(update.file.path)
            throw error
        }
        idsByPath?[session.path] = session.id
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
#endif
