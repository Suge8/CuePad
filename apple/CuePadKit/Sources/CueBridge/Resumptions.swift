#if os(macOS)
import CueStore

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
