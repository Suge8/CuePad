import Foundation

/// 常驻的跟随者（跟着流或通知直到被取消）的生命期：全部是同一个任务组里的子任务，取消一次就全部停。
/// 起跟随者用 `AppServices.follow`；一个跟随者出错只报告，不拖垮别的。
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

    func cancelAll() {
        sink?.finish()
        sink = nil
        supervisor?.cancel()
        supervisor = nil
    }
}

extension AppServices {
    func follow(_ body: @escaping Followers.Body) {
        tasks.add(body)
    }

    /// 同上；出错时报告 `issue` 一次，被取消不算出错。
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
