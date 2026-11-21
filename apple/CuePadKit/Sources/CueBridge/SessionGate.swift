#if os(macOS)
import Foundation

@MainActor
final class SessionGate {
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var generation = 0
    private var busy: Set<Session.ID> = []
    private var queue: [Session.ID: [Waiter]] = [:]

    func run<T>(_ id: Session.ID, _ body: () async throws -> T) async throws -> T {
        let admittedGeneration = generation
        try await enter(id)
        defer { leave(id) }
        guard admittedGeneration == generation else { throw CancellationError() }
        return try await body()
    }

    func stop() {
        generation += 1
        for id in Array(queue.keys) { abort(id) }
    }

    func abort(_ id: Session.ID) {
        for waiter in queue.removeValue(forKey: id) ?? [] { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func enter(_ id: Session.ID) async throws {
        guard busy.contains(id) else {
            busy.insert(id)
            return
        }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { queue[id, default: []].append(Waiter(token: token, continuation: $0)) }
        } onCancel: {
            Task { @MainActor in self.cancel(token, in: id) }
        }
    }

    private func leave(_ id: Session.ID) {
        guard var waiting = queue[id], !waiting.isEmpty else { return _ = busy.remove(id) }
        let next = waiting.removeFirst()
        queue[id] = waiting.isEmpty ? nil : waiting
        next.continuation.resume()
    }

    private func cancel(_ token: UUID, in id: Session.ID) {
        guard let index = queue[id]?.firstIndex(where: { $0.token == token }) else { return }
        let waiter = queue[id]!.remove(at: index)
        if queue[id]?.isEmpty == true { queue[id] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
#endif
