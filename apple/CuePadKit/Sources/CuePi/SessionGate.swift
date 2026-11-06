#if os(macOS)
import Foundation

/// 同一会话的发话一次一句：`PiBridge.send` 先在这里排队，前一句交出（含它停下在跑那一轮的等待）有了结果才轮到下一句。
/// 各家的发话是"先停下这一轮、等它收尾、再开新一轮"，两句并发会都等同一次收尾、放行后各开一轮，所以串行放在所有接入共过的这一处，
/// 不在各家各写一套。停止（`abort`）与斜杠命令不排队（命令可以很久才确认，如 `/compact`，发话要能在它进行中打断它；带话的命令各家自己照旧）：卡住的那句靠各家等待自己的时限（`AgentTimeouts.stop`）放弃，停止本身也走同一套。
/// 排队的调用方被取消时离队、以取消结束。
/// `abort(_:)` 取消该会话排着的发话（以 `CancellationError` 结束）：停下之后不该让排着的发话又开一轮；正在做的那句若还卡在"等上一轮停下"，由各家的 `StopPhase` 整段取消；已经交出新话后的等待（Claude 等送达、Codex 的 `turn/start`）不随中止取消——话已交出，抛取消会把已收下的话误报成未确认、引起重发。
@MainActor
final class SessionGate {
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var busy: Set<PiSession.ID> = []
    private var queue: [PiSession.ID: [Waiter]] = [:]

    func run<T>(_ id: PiSession.ID, _ body: () async throws -> T) async throws -> T {
        try await enter(id)
        defer { leave(id) }
        return try await body()
    }

    /// 停止：排着的发话不再开轮，以取消结束。
    func abort(_ id: PiSession.ID) {
        for waiter in queue.removeValue(forKey: id) ?? [] { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func enter(_ id: PiSession.ID) async throws {
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

    /// 把位置交给队首（`busy` 不放开），没有人排队才放开。
    private func leave(_ id: PiSession.ID) {
        guard var waiting = queue[id], !waiting.isEmpty else { return _ = busy.remove(id) }
        let next = waiting.removeFirst()
        queue[id] = waiting.isEmpty ? nil : waiting
        next.continuation.resume()
    }

    private func cancel(_ token: UUID, in id: PiSession.ID) {
        guard let index = queue[id]?.firstIndex(where: { $0.token == token }) else { return }
        let waiter = queue[id]!.remove(at: index)
        if queue[id]?.isEmpty == true { queue[id] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
#endif
