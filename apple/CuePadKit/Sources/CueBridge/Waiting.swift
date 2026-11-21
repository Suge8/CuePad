#if os(macOS)
import CueStore
import Foundation

public enum AgentTimeouts {
    public static let ack: Duration = .seconds(10)
    public static let reply: Duration = .seconds(60)
    public static let probe: Duration = .seconds(20)
    public static let launch: Duration = .seconds(30)
    public static let end: Duration = .seconds(10)
    public static let command: Duration = .seconds(10)
    public static let shell: Duration = .seconds(5)
    public static let settleAsk: Duration = .seconds(5)
    public static let list: Duration = .seconds(15)
    public static let endGrace: Duration = .seconds(5)
    public static let stop: Duration = .seconds(30)
    public static let hostedIdle: Duration = .seconds(30 * 60)
}

func withDeadline<T: Sendable>(
    _ limit: Duration, timing: Timing = .system, orThrow timeout: any Error, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await timing.sleep(limit)
            throw timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@MainActor
final class StopPhase {
    private var running: [UUID: Task<Void, any Error>] = [:]
    private var generation = 0

    func run(cancellable: Bool = true, _ body: @escaping @MainActor () async throws -> Void) async throws {
        let id = UUID()
        let started = generation
        let work = Task { try await body() }
        if cancellable { running[id] = work }
        defer { running[id] = nil }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        if cancellable, generation != started { throw CancellationError() }
    }

    func cancelAll() {
        generation += 1
        for work in running.values { work.cancel() }
    }
}

@MainActor
final class PendingReplies<ID: Hashable & Sendable, Reply: Sendable> {
    private var waiting: [ID: CheckedContinuation<Reply, any Error>] = [:]
    private var closed: (any Error)?
    private let timeout: Duration?
    private let timing: Timing
    private let timeoutError: any Error

    init(timeout: Duration?, timing: Timing = .system, timeoutError: any Error) {
        self.timeout = timeout
        self.timing = timing
        self.timeoutError = timeoutError
    }

    var isClosed: Bool { closed != nil }

    func request(_ id: ID, send: () throws -> Void) async throws -> Reply {
        if let closed { throw closed }
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                do {
                    try send()
                } catch {
                    waiting.removeValue(forKey: id)?.resume(throwing: error)
                    return
                }
                guard let timeout else { return }
                let (deadline, error, timing) = (timing.now().addingTimeInterval(timeout.seconds), timeoutError, timing)
                timer = Task { [weak self] in
                    guard (try? await timing.sleepUntil(deadline)) != nil else { return }
                    self?.waiting.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    @discardableResult
    func resolve(_ id: ID, with result: Result<Reply, any Error>) -> Bool {
        guard let continuation = waiting.removeValue(forKey: id) else { return false }
        continuation.resume(with: result)
        return true
    }

    fileprivate func releaseAll() where Reply == Void {
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume() }
    }

    func closeAll(_ error: any Error) {
        closed = error
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume(throwing: error) }
    }
}

@MainActor
final class Occurrences {
    private(set) var count = 0
    private let waiting: PendingReplies<UUID, Void>

    init(timeout: Duration?, timing: Timing = .system, timeoutError: any Error) {
        waiting = PendingReplies(timeout: timeout, timing: timing, timeoutError: timeoutError)
    }

    func happened() {
        count += 1
        waiting.releaseAll()
    }

    func wait(after seen: Int) async throws {
        guard count == seen else { return }
        try await next()
    }

    func next() async throws {
        _ = try await waiting.request(UUID()) {}
    }

    func closeAll(_ error: any Error) {
        waiting.closeAll(error)
    }
}
#endif
