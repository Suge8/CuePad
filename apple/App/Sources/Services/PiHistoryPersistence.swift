#if os(macOS)
import CryptoKit
import CuePi
import CueStore
import Foundation

/// Pi 历史索引的落盘：会话行进 Store（本机表），可续读的检查点存为缓存文件——
/// 检查点含分支树，只靠 Store 里的读取偏移无法从中断处继续。
nonisolated struct PiHistoryPersistence: Sendable {
    let store: CueStore
    let checkpoints: URL

    func checkpoint(for file: URL) -> PiHistoryCheckpoint? {
        try? JSONDecoder().decode(PiHistoryCheckpoint.self, from: Data(contentsOf: checkpointURL(file)))
    }

    /// 先落检查点再写会话行：中途失败时下次从旧检查点重读，不会漏掉内容。
    func persist(_ update: PiHistoryUpdate) async throws {
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try JSONEncoder().encode(update.checkpoint).write(to: checkpointURL(update.file), options: .atomic)
        let history = update.history
        let firstPrompt = history.turns.first?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.titleLimit)
        let modified = try? update.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await store.upsertPiSession(
            StoredPiSession(
                id: history.sessionID ?? update.file.deletingPathExtension().lastPathComponent,
                path: update.file.path,
                cwd: history.cwd ?? "",
                title: history.name ?? firstPrompt.map(String.init) ?? "",
                lastActivityAt: history.lastActivity ?? modified ?? .distantPast,
                readOffset: Int(update.checkpoint.offset)))
    }

    private static let titleLimit = 80

    private func checkpointURL(_ file: URL) -> URL {
        let name = SHA256.hash(data: Data(file.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return checkpoints.appending(path: name + ".json")
    }
}
#endif
