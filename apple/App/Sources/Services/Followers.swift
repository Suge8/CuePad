import Foundation

final class Followers {
    typealias Body = @MainActor () async -> Void

    private var sink: AsyncStream<Body>.Continuation?
    private var supervisor: Task<Void, Never>?

    var isRunning: Bool { sink != nil }

    func add(_ body: @escaping Body) {
        if sink == nil {
            let (bodies, sink) = AsyncStream<Body>.makeStream()
            self.sink = sink
            supervisor = Task { await Self.run(bodies) }
        }
        sink?.yield(body)
    }

    private static func run(_ bodies: AsyncStream<Body>) async {
        await withDiscardingTaskGroup { group in
            for await next in bodies {
                group.addTask { await next() }
            }
        }
    }

    @discardableResult
    func cancelAll() -> Task<Void, Never>? {
        sink?.finish()
        sink = nil
        supervisor?.cancel()
        return supervisor
    }
}

extension AppServices {
    func follow(_ body: @escaping Followers.Body) {
        tasks.add(body)
    }

    func follow(reporting issue: @escaping @Sendable (any Error) -> StartupIssue, _ body: @escaping @MainActor () async throws -> Void) {
        follow {
            do {
                try await body()
            } catch where !Task.isCancelled {
                self.reportIssue(issue(error))
            } catch {}
        }
    }
}
