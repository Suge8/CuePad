#if os(macOS)
import CueStore

/// 同一会话同时只有一次恢复（`AgentRuntime.resume` 起进程的几家各持一份）：进行中再来的等同一个结果、拿到同一个 id，
/// 不会两个进程同写一个会话文件。取消只放走这一个调用方（立即抛 `CancellationError`）；都放弃了才取消这次恢复，
/// 它照没连上的规则收掉自己起的进程，收完之前再来的恢复等它收完、另起一次。
@MainActor
final class Resumptions {
    private final class Pending {
        var work: Task<Session.ID, any Error>?
        var waiters = 0
    }

    private var pending: [String: Pending] = [:]

    func resume(_ sessionID: String, start: @escaping @MainActor () async throws -> Session.ID) async throws -> Session.ID {
        while let abandoned = pending[sessionID]?.work, abandoned.isCancelled { _ = await abandoned.result }
        let current = pending[sessionID] ?? begin(sessionID, start)
        let work = current.work!
        current.waiters += 1
        defer { current.waiters -= 1 }
        do {
            return try await abandonable { try await work.value }
        } catch {
            if current.waiters == 1, Task.isCancelled { work.cancel() }
            throw error
        }
    }

    private func begin(_ sessionID: String, _ start: @escaping @MainActor () async throws -> Session.ID) -> Pending {
        let current = Pending()
        pending[sessionID] = current
        current.work = Task {
            defer { if pending[sessionID] === current { pending[sessionID] = nil } }
            return try await start()
        }
        return current
    }
}
#endif
