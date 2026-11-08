import Foundation

/// 一次会话的异步操作归它自己所有。取消立即恢复本地 continuation；迟到的系统回调只访问已结束的旧作用域。
final class VoiceOperationScope {
    private(set) var ended = false
    private var pending: [UUID: () -> Void] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    @discardableResult func end() -> [Task<Void, Never>] {
        guard !ended else { return [] }
        ended = true
        let work = Array(tasks.values)
        tasks.removeAll()
        work.forEach { $0.cancel() }
        let cancellations = pending.values
        pending.removeAll()
        cancellations.forEach { $0() }
        return work
    }

    @discardableResult func spawn(_ work: @escaping () async -> Void) -> Task<Void, Never>? {
        guard !ended else { return nil }
        let id = UUID()
        let task = Task { await work(); tasks[id] = nil }
        tasks[id] = task
        return task
    }

    func perform<Value: Sendable>(_ work: @escaping () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !ended else { throw CancellationError() }
        let operation = Task { try await work() }
        defer { operation.cancel() }
        return try await withTaskCancellationHandler {
            try await wait { finish in self.spawn { finish(await operation.result) } }
        } onCancel: {
            operation.cancel()
        }
    }

    func wait<Value: Sendable>(_ start: (@escaping @MainActor @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try Task.checkCancellation()
        guard !ended else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = { continuation.resume(throwing: CancellationError()) }
                start { [weak self] result in
                    guard self?.pending.removeValue(forKey: id) != nil else { return }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.pending.removeValue(forKey: id)?() }
        }
    }
}
