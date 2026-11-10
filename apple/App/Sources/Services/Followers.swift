import Foundation

/// 常驻的跟随者（跟着流或通知直到被取消）的生命期：全部是同一个任务组里的子任务，取消一次就全部停。
/// 起跟随者用 `AppServices.follow`；一个跟随者出错只报告，不拖垮别的。
final class Followers {
    typealias Body = @MainActor () async -> Void

    private var sink: AsyncStream<Body>.Continuation?
    /// 取消过又起的（退出收尾里还有人 `follow`）另起一组，前面的照样留着等：取消后放不放掉资料库要看全部几组。
    private var supervisors: [Task<Void, Never>] = []

    var isRunning: Bool { sink != nil }

    func add(_ body: @escaping Body) {
        if sink == nil {
            let (bodies, sink) = AsyncStream<Body>.makeStream()
            self.sink = sink
            supervisors.append(Task { await Self.run(bodies) })
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

    /// 返回的等待在至今起过的全部跟随者收尾后结束。
    @discardableResult
    func cancelAll() -> @Sendable () async -> Void {
        sink?.finish()
        sink = nil
        for supervisor in supervisors { supervisor.cancel() }
        return { [supervisors] in for supervisor in supervisors { await supervisor.value } }
    }
}

/// 不等结果的一次性工作（马上上传这几条）：不取消，`cancelBackgroundWork` 的等待等它们做完，做完前它们攥着服务与资料库。
final class InFlight {
    private var running: [UUID: Task<Void, Never>] = [:]

    func run(_ body: @escaping @MainActor () async -> Void) {
        let id = UUID()
        running[id] = Task {
            await body()
            self.running[id] = nil
        }
    }

    func settled() -> @Sendable () async -> Void {
        { [tasks = Array(running.values)] in for task in tasks { await task.value } }
    }
}

extension AppServices {
    func follow(_ body: @escaping Followers.Body) {
        tasks.add(body)
    }

    func uploadSoon(_ records: UUID..., deleted: Bool = false) {
        inFlight.run { [sync] in await sync?.upload(records, deleted: deleted) }
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
